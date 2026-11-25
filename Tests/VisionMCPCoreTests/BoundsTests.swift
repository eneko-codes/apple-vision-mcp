import CoreGraphics
import CoreText
import Foundation
import Testing

@testable import VisionMCPCore

/// A document held in memory: `texts` is the recognised text of each page and `codes` the
/// codes found on it. It follows the real store's contract (the range is cut to the file,
/// reading stops once the text budget is reached) so that the tool layer is driven the way
/// it is driven in use, without opening a file. Everything in it is invented.
private struct ScriptedStore: VisionStore {
    var texts: [String] = []
    var codes: [[BarcodeContent.Barcode]] = []
    var pageCount: Int { Swift.max(texts.count, codes.count) }

    func canonicalise(_ path: String) throws -> CanonicalPath { CanonicalPath(path: path, exists: true) }
    func probe(_ path: String) -> RootState { .reachable }

    func ocr(
        _ path: ScopedPath, pages: PageRange, languages: [String], characterBudget: Int,
        deadline: ContinuousClock.Instant
    ) async throws -> OCRContent {
        var read: [OCRContent.Page] = []
        let last = Swift.min(pages.last, texts.count)
        if pages.first <= last {
            for number in pages.first...last {
                read.append(.init(number: number, lines: texts[number - 1].split(separator: "\n").map(String.init)))
                if read.reduce(0, { $0 + $1.text.count }) >= characterBudget { break }
            }
        }
        return OCRContent(
            pages: read, source: texts.count > 1 ? "pdf" : "image", recognisedLanguages: ["(Vision's choice)"],
            pageCount: texts.count)
    }

    func barcodes(_ path: ScopedPath, pages: PageRange, deadline: ContinuousClock.Instant)
        async throws -> BarcodeContent
    {
        var read: [BarcodeContent.Page] = []
        let last = Swift.min(pages.last, codes.count)
        if pages.first <= last {
            for number in pages.first...last {
                read.append(.init(number: number, pixelWidth: 800, pixelHeight: 1000, barcodes: codes[number - 1]))
            }
        }
        return BarcodeContent(pages: read, source: codes.count > 1 ? "pdf" : "image", pageCount: codes.count)
    }
}

/// A store that never answers, for the deadline.
private struct HangingStore: VisionStore {
    func canonicalise(_ path: String) throws -> CanonicalPath { CanonicalPath(path: path, exists: true) }
    func probe(_ path: String) -> RootState { .reachable }
    func ocr(
        _ path: ScopedPath, pages: PageRange, languages: [String], characterBudget: Int,
        deadline: ContinuousClock.Instant
    ) async throws -> OCRContent {
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        throw ToolError.storeFailure("unreachable")
    }
    func barcodes(_ path: ScopedPath, pages: PageRange, deadline: ContinuousClock.Instant)
        async throws -> BarcodeContent
    {
        throw ToolError.storeFailure("unreachable")
    }
}

/// The edges of the tool standard for this server's tools: each bound and one past it, the
/// text of each notice, pages that chain, the longest result, and the texts the model reads.
@Suite("Bounds")
struct BoundsTests {

    private func tools(
        _ store: any VisionStore, roots: [String] = ["/invented"],
        timeout: Duration = VisionTools.defaultTimeout,
        budget: Duration = VisionTools.defaultRecognitionBudget
    ) -> VisionTools {
        var configuration = Configuration()
        configuration.readRoots = roots
        return VisionTools(
            store: store, configuration: configuration, timeout: timeout, recognitionBudget: budget)
    }

    private func call(
        _ tool: String, _ arguments: [String: Value] = [:], store: any VisionStore,
        roots: [String] = ["/invented"], timeout: Duration = VisionTools.defaultTimeout,
        budget: Duration = VisionTools.defaultRecognitionBudget
    ) async -> ToolOutput {
        var all = arguments
        if tool != ToolCatalog.statusName, all["path"] == nil { all["path"] = "/invented/file" }
        return await tools(store, roots: roots, timeout: timeout, budget: budget).handle(
            ToolCall(name: tool, arguments: all))
    }

    /// A page of `width` characters in lines of 60, each line numbered so that a window
    /// can be told from any other.
    private static func page(_ number: Int, width: Int = 1_500) -> String {
        var text = ""
        var line = 0
        while text.count < width {
            text += "P\(number)L\(line) " + String(repeating: "x", count: 50) + "\n"
            line += 1
        }
        return String(text.prefix(width))
    }

    private static func document(pages: Int, width: Int = 1_500) -> ScriptedStore {
        ScriptedStore(texts: (1...pages).map { page($0, width: width) })
    }

    private func pageNumbers(in text: String) -> [Int] {
        text.matches(of: /── page (\d+) ──/).compactMap { Int($0.1) }
    }

    // MARK: vision_ocr pages

    @Test("A call with no optional argument returns whole pages up to about one usual page, announced first")
    func ocrDefaultPage() async throws {
        let result = await call(ToolCatalog.ocrName, store: Self.document(pages: 30))
        #expect(!result.isError)
        let shown = pageNumbers(in: result.text)
        #expect(shown == Array(1...shown.count))
        #expect(shown.count < 30)
        #expect(
            result.text.hasPrefix(
                "Pages 1–\(shown.count) of 30. Pass first_page=\(shown.count + 1) for the next pages.\n\n"))
        #expect(result.text.utf16.count <= ToolStandard.usualPage + 400)
    }

    @Test("A document that fits carries no notice")
    func ocrWholeDocument() async {
        let result = await call(ToolCatalog.ocrName, store: Self.document(pages: 3, width: 800))
        #expect(pageNumbers(in: result.text) == [1, 2, 3])
        #expect(!result.text.contains("Pages "))
        #expect(!result.text.contains("is outside"))
    }

    @Test("Following first_page from each notice reads every page once, in order")
    func ocrPagesChain() async throws {
        let store = Self.document(pages: 30)
        var seen: [Int] = []
        var next = 1
        for _ in 0..<30 {
            let result = await call(ToolCatalog.ocrName, ["first_page": .int(next)], store: store)
            let shown = pageNumbers(in: result.text)
            seen += shown
            if result.text.contains("That is all.") { break }
            next = try #require(shown.last) + 1
        }
        #expect(seen == Array(1...30))
    }

    @Test("A last_page beyond the pages one call reads is moved, and the notice says which was used")
    func ocrLastPageMoved() async {
        let store = Self.document(pages: 60, width: 10)
        let atLimit = await call(
            ToolCatalog.ocrName,
            ["last_page": .int(ToolCatalog.ocrPagesPerCall), "max_characters": .int(20_000)], store: store)
        #expect(!atLimit.text.contains("is outside"))
        #expect(pageNumbers(in: atLimit.text).count == ToolCatalog.ocrPagesPerCall)

        let past = await call(
            ToolCatalog.ocrName,
            ["last_page": .int(ToolCatalog.ocrPagesPerCall + 1), "max_characters": .int(20_000)], store: store)
        let used = ToolCatalog.ocrPagesPerCall
        #expect(past.text.contains("last_page=\(used + 1) is outside 1–\(used); \(used) was used."))
        #expect(pageNumbers(in: past.text).count == used)
        #expect(past.text.contains("Pages 1–\(used) of 60. Pass first_page=\(used + 1) for the next pages."))
    }

    @Test("A page number past the end says the file ends sooner")
    func ocrPastTheEnd() async {
        let result = await call(ToolCatalog.ocrName, ["first_page": .int(50)], store: Self.document(pages: 30))
        #expect(!result.isError)
        #expect(result.text.hasPrefix("Pages 0 of 30: first_page=50 is past the end. That is all.\n\n"))
    }

    @Test("A first_page below 1 is moved and a last_page before first_page is refused")
    func ocrPageArguments() async {
        let store = Self.document(pages: 2, width: 100)
        let low = await call(ToolCatalog.ocrName, ["first_page": .int(0)], store: store)
        #expect(low.text.contains("first_page=0 is outside 1–\(ToolCatalog.pageNumberRange.upperBound); 1 was used."))
        let backwards = await call(
            ToolCatalog.ocrName, ["first_page": .int(5), "last_page": .int(2)], store: store)
        #expect(backwards.isError)
        #expect(backwards.text.contains("last_page"))
        #expect(backwards.text.contains("first_page"))
    }

    // MARK: vision_ocr one long page

    @Test("A page longer than max_characters is read in windows that chain and join to the page")
    func ocrWindowsChain() async throws {
        let text = Self.page(1, width: 25_000)
        let store = ScriptedStore(texts: [text, "second"])
        var joined = ""
        var offset = 0
        for _ in 0..<10 {
            let result = await call(
                ToolCatalog.ocrName,
                ["first_page": .int(1), "character_offset": .int(offset), "max_characters": .int(10_000)],
                store: store)
            #expect(!result.isError)
            #expect(result.text.utf16.count <= ToolStandard.longestResult)
            let notice = try #require(result.text.firstMatch(of: /characters (\d+)–(\d+) of 25000\./))
            #expect(Int(notice.1) == offset + 1)
            let end = try #require(Int(notice.2))
            // The window is the text between the blank line after the notices and its end.
            let body = String(result.text.split(separator: "\n\n", maxSplits: 3).last ?? "")
            joined += body
            if result.text.contains("Pass character_offset=") { offset = end } else { break }
        }
        #expect(joined.replacingOccurrences(of: "\n", with: "") .hasSuffix(String(text.suffix(30)).replacingOccurrences(of: "\n", with: "")))
        #expect(offset == 20_000)
    }

    @Test("The window notice names the page and the first_page that reads it")
    func ocrWindowNotice() async {
        let store = ScriptedStore(texts: ["short", Self.page(2, width: 30_000)])
        let result = await call(
            ToolCatalog.ocrName,
            ["first_page": .int(2), "max_characters": .int(10_000)], store: store)
        #expect(
            result.text.contains(
                "Page 2, read with first_page=2: characters 1–10000 of 30000. Pass character_offset=10000 for the rest."))
        #expect(!result.text.contains("Pages "))
        let last = await call(
            ToolCatalog.ocrName,
            ["first_page": .int(2), "character_offset": .int(20_000), "max_characters": .int(10_000)],
            store: store)
        #expect(last.text.contains("characters 20001–30000 of 30000. That is all."))
        #expect(last.text.contains("Pages 2–2 of 2. That is all."))
        let beyond = await call(
            ToolCatalog.ocrName, ["first_page": .int(2), "character_offset": .int(40_000)], store: store)
        #expect(beyond.text.contains("character_offset=40000 is past the end. That is all."))
    }

    @Test("max_characters outside its range is moved and the result says so")
    func ocrMaxCharacters() async {
        let store = Self.document(pages: 1, width: 100)
        let upper = ToolCatalog.maxCharactersRange.upperBound
        let atMaximum = await call(ToolCatalog.ocrName, ["max_characters": .int(upper)], store: store)
        #expect(!atMaximum.text.contains("is outside"))
        let past = await call(ToolCatalog.ocrName, ["max_characters": .int(upper + 1)], store: store)
        #expect(past.text.contains("max_characters=\(upper + 1) is outside 1–\(upper); \(upper) was used."))
        let zero = await call(ToolCatalog.ocrName, ["max_characters": .int(0)], store: store)
        #expect(zero.text.contains("max_characters=0 is outside 1–\(upper); 1 was used."))
    }

    @Test("The longest window of the widest characters still fits a result without the guard")
    func ocrWidestWindow() async {
        // Each emoji is two UTF-16 units, so the longest window holds twice as many units.
        let wide = String(repeating: "😀", count: ToolCatalog.maxCharactersRange.upperBound)
        let result = await call(
            ToolCatalog.ocrName, ["max_characters": .int(ToolCatalog.maxCharactersRange.upperBound)],
            store: ScriptedStore(texts: [wide]))
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
        #expect(!result.text.hasPrefix("Cut at"))
        #expect(result.text.contains("Pass character_offset="))
    }

    @Test("character_offset and first_page are moved at their edges and the result says so")
    func ocrOffsetEdges() async {
        let store = ScriptedStore(texts: [Self.page(1, width: 500)])
        let offsetMaximum = ToolCatalog.characterOffsetRange.upperBound
        let at = await call(ToolCatalog.ocrName, ["character_offset": .int(offsetMaximum)], store: store)
        #expect(!at.text.contains("is outside"))
        let past = await call(ToolCatalog.ocrName, ["character_offset": .int(offsetMaximum + 1)], store: store)
        #expect(past.text.contains("character_offset=\(offsetMaximum + 1) is outside 0–\(offsetMaximum); \(offsetMaximum) was used."))
        let negative = await call(ToolCatalog.ocrName, ["character_offset": .int(-1)], store: store)
        #expect(negative.text.contains("character_offset=-1 is outside 0–\(offsetMaximum); 0 was used."))

        let pageMaximum = ToolCatalog.pageNumberRange.upperBound
        let lastPage = await call(ToolCatalog.ocrName, ["first_page": .int(pageMaximum)], store: store)
        #expect(!lastPage.text.contains("is outside"))
        let beyond = await call(ToolCatalog.ocrName, ["first_page": .int(pageMaximum + 1)], store: store)
        #expect(beyond.text.contains("first_page=\(pageMaximum + 1) is outside 1–\(pageMaximum); \(pageMaximum) was used."))
    }

    // MARK: Arguments

    @Test("An argument the tool does not list is refused with the names that are allowed")
    func unknownArgumentRefused() async {
        for (tool, allowed) in [
            (ToolCatalog.statusName, "limit, offset"),
            (ToolCatalog.ocrName, "character_offset, first_page, languages, last_page, max_characters, path"),
            (ToolCatalog.barcodesName, "first_page, last_page, limit, offset, path"),
        ] {
            let result = await call(tool, ["page_size": .int(5)], store: Self.document(pages: 1))
            #expect(result.isError)
            #expect(result.text.contains("page_size"))
            #expect(result.text.contains("Allowed: \(allowed)"))
        }
    }

    @Test("A value of the wrong type is refused with the form expected")
    func wrongTypeRefused() async {
        let store = Self.document(pages: 1)
        let page = await call(ToolCatalog.ocrName, ["first_page": .string("two")], store: store)
        #expect(page.isError)
        #expect(page.text.contains("a whole number was expected"))
        let languages = await call(ToolCatalog.ocrName, ["languages": .string("es-ES")], store: store)
        #expect(languages.isError)
        #expect(languages.text.contains("an array of strings was expected"))
        let path = await call(ToolCatalog.ocrName, ["path": .int(4)], store: store)
        #expect(path.isError)
        #expect(path.text.contains("text was expected"))
    }

    @Test("An error repeats a long path only up to the echo width")
    func errorsClipWhatTheyEcho() async {
        let long = "/elsewhere/" + String(repeating: "a", count: 5_000)
        let result = await call(ToolCatalog.ocrName, ["path": .string(long)], store: Self.document(pages: 1))
        #expect(result.isError)
        #expect(result.text.utf16.count < 2_000)
        #expect(!result.text.contains(String(repeating: "a", count: ToolStandard.echoWidth + 1)))
    }

    // MARK: vision_barcodes

    private static func codes(_ count: Int, payloadWidth: Int = 60) -> [BarcodeContent.Barcode] {
        // Created in reverse reading order, so the tool has to sort them.
        (0..<count).reversed().map { index in
            let label = String(format: "%04d", index)
            return BarcodeContent.Barcode(
                symbology: "QR",
                payload: label + String(repeating: "p", count: payloadWidth - label.count),
                x: 10, y: 10 + index, width: 100, height: 100)
        }
    }

    private func labels(in text: String) -> [Int] {
        text.matches(of: /payload\s+(\d{4})p/).compactMap { Int($0.1) }
    }

    @Test("Codes come one page at a time, in a stated order, announced before the data")
    func barcodeDefaultPage() async {
        let store = ScriptedStore(codes: [Self.codes(120)])
        let result = await call(ToolCatalog.barcodesName, store: store)
        #expect(!result.isError)
        let limit = ToolCatalog.defaultBarcodeLimit
        #expect(
            result.text.hasPrefix("Showing 1–\(limit) of 120 codes. Pass offset=\(limit) for the next page.\n\n"))
        #expect(labels(in: result.text) == Array(0..<limit))
        #expect(result.text.utf16.count <= ToolStandard.usualPage)
    }

    @Test("Following offset from each notice reads every code once")
    func barcodePagesChain() async throws {
        let store = ScriptedStore(codes: [Self.codes(120)])
        var seen: [Int] = []
        var offset = 0
        for _ in 0..<10 {
            let result = await call(ToolCatalog.barcodesName, ["offset": .int(offset)], store: store)
            seen += labels(in: result.text)
            if result.text.contains("That is all.") { break }
            offset = seen.count
        }
        #expect(seen == Array(0..<120))
    }

    @Test("limit at its maximum is used as asked and fits a result; one past it is moved")
    func barcodeLimitEdges() async {
        let store = ScriptedStore(codes: [Self.codes(150)])
        let maximum = ToolCatalog.barcodeLimitRange.upperBound
        let at = await call(ToolCatalog.barcodesName, ["limit": .int(maximum)], store: store)
        #expect(!at.text.contains("is outside"))
        #expect(labels(in: at.text).count == maximum)
        #expect(at.text.utf16.count <= ToolStandard.longestResult)
        let past = await call(ToolCatalog.barcodesName, ["limit": .int(maximum + 1)], store: store)
        #expect(past.text.contains("limit=\(maximum + 1) is outside 1–\(maximum); \(maximum) was used."))
        let zero = await call(ToolCatalog.barcodesName, ["limit": .int(0)], store: store)
        #expect(zero.text.contains("limit=0 is outside 1–\(maximum); 1 was used."))
    }

    @Test("An offset past the end says so")
    func barcodeOffsetPastTheEnd() async {
        let store = ScriptedStore(codes: [Self.codes(5)])
        let result = await call(ToolCatalog.barcodesName, ["offset": .int(9)], store: store)
        #expect(result.text.hasPrefix("Showing 0 of 5 codes: offset=9 is past the end. That is all."))
    }

    @Test("A page of very wide payloads is halved rather than cut, and the notice stays true")
    func barcodeWidePayloads() async throws {
        let wide = (0..<100).map { index -> BarcodeContent.Barcode in
            let label = String(format: "%04d", index)
            return .init(
                symbology: "QR", payload: label + String(repeating: "p", count: 4_000), x: 1, y: index,
                width: 1, height: 1)
        }
        let result = await call(
            ToolCatalog.barcodesName, ["limit": .int(100)], store: ScriptedStore(codes: [wide]))
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
        let shown = labels(in: result.text).count
        #expect(shown < 100)
        #expect(result.text.hasPrefix("Showing 1–\(shown) of 100 codes. Pass offset=\(shown) for the next page."))
    }

    @Test("A document with more pages than one call scans says so, with the next first_page")
    func barcodePagesNotice() async {
        let store = ScriptedStore(codes: Array(repeating: [], count: 60))
        let result = await call(ToolCatalog.barcodesName, store: store)
        let limit = ToolCatalog.barcodePagesPerCall
        #expect(result.text.contains("Pages 1–\(limit) of 60. Pass first_page=\(limit + 1) for the next pages."))
        let past = await call(ToolCatalog.barcodesName, ["last_page": .int(limit + 5)], store: store)
        #expect(past.text.contains("last_page=\(limit + 5) is outside 1–\(limit); \(limit) was used."))
    }

    // MARK: vision_status

    @Test("Folders come one page at a time in the order they were configured")
    func statusPages() async {
        let roots = (0..<30).map { "/invented/root\(String(format: "%02d", $0))" }
        let first = await call(ToolCatalog.statusName, store: ScriptedStore(), roots: roots)
        let limit = ToolCatalog.defaultRootLimit
        #expect(first.text.hasPrefix("Showing 1–\(limit) of 30 read roots. Pass offset=\(limit) for the next page.\n\n"))
        #expect(first.text.contains("/invented/root00"))
        #expect(!first.text.contains("/invented/root\(limit)"))
        let second = await call(
            ToolCatalog.statusName, ["offset": .int(limit)], store: ScriptedStore(), roots: roots)
        #expect(second.text.hasPrefix("Showing \(limit + 1)–30 of 30 read roots. That is all."))
        #expect(second.text.contains("/invented/root\(limit)"))
        let whole = await call(ToolCatalog.statusName, store: ScriptedStore(), roots: ["/invented"])
        #expect(!whole.text.contains("Showing"))
    }

    @Test("limit and offset of the folder listing are held at their edges")
    func statusEdges() async {
        let roots = (0..<30).map { "/invented/root\($0)" }
        let maximum = ToolCatalog.rootLimitRange.upperBound
        let at = await call(ToolCatalog.statusName, ["limit": .int(maximum)], store: ScriptedStore(), roots: roots)
        #expect(!at.text.contains("is outside"))
        let past = await call(ToolCatalog.statusName, ["limit": .int(maximum + 1)], store: ScriptedStore(), roots: roots)
        #expect(past.text.contains("limit=\(maximum + 1) is outside 1–\(maximum); \(maximum) was used."))
        let zero = await call(ToolCatalog.statusName, ["limit": .int(0)], store: ScriptedStore(), roots: roots)
        #expect(zero.text.contains("limit=0 is outside 1–\(maximum); 1 was used."))
        let beyond = await call(ToolCatalog.statusName, ["offset": .int(99)], store: ScriptedStore(), roots: roots)
        #expect(beyond.text.contains("Showing 0 of 30 read roots: offset=99 is past the end. That is all."))
    }

    // MARK: Deadline

    @Test("A call that never finishes is answered with an error at its deadline", .timeLimit(.minutes(1)))
    func hardDeadline() async {
        let result = await call(
            ToolCatalog.ocrName, store: HangingStore(), timeout: .milliseconds(200))
        #expect(result.isError)
        #expect(result.text.contains("did not finish"))
        #expect(result.text.contains("nothing was changed"))
        #expect(result.text.utf16.count <= ToolStandard.longestError)
    }

    // MARK: Texts the model reads

    @Test("No instructions or description is longer than a client reads")
    func textsFit() {
        #expect(
            ToolStandard.overlongTexts(
                instructions: VisionMCPServer.instructions, catalog: ToolCatalog.all()).isEmpty)
    }

    @Test("Every bound the texts state is the constant the code enforces")
    func statedBoundsMatch() throws {
        let ocr = try #require(ToolCatalog.all().first { $0.name == ToolCatalog.ocrName })
        let description = try #require(ocr.description)
        #expect(description.contains("\(ToolCatalog.ocrPagesPerCall) pages"))
        #expect(description.contains("\(ToolCatalog.defaultMaxCharacters) characters"))
        #expect(description.contains("\(VisionTools.defaultTimeout.components.seconds) seconds"))
        #expect(description.contains("\(VisionTools.defaultRecognitionBudget.components.seconds) seconds"))
        #expect(VisionMCPServer.instructions.contains("\(ToolCatalog.barcodePagesPerCall) pages"))
        #expect(VisionTools.defaultTimeout < ToolStandard.timeLimit)
        #expect(VisionTools.defaultRecognitionBudget < VisionTools.defaultTimeout)
        #expect(ToolCatalog.defaultMaxCharacters == ToolStandard.usualPage)

        func schemaBounds(_ tool: String, _ argument: String) throws -> (Int?, Int?, Int?) {
            let tool = try #require(ToolCatalog.all().first { $0.name == tool })
            guard case .object(let schema) = tool.inputSchema,
                case .object(let properties)? = schema["properties"],
                case .object(let property)? = properties[argument]
            else { throw ToolError.missingArgument(argument) }
            return (property["minimum"]?.intValue, property["maximum"]?.intValue, property["default"]?.intValue)
        }
        let limit = try schemaBounds(ToolCatalog.barcodesName, "limit")
        #expect(limit.0 == ToolCatalog.barcodeLimitRange.lowerBound)
        #expect(limit.1 == ToolCatalog.barcodeLimitRange.upperBound)
        #expect(limit.2 == ToolCatalog.defaultBarcodeLimit)
        let window = try schemaBounds(ToolCatalog.ocrName, "max_characters")
        #expect(window.1 == ToolCatalog.maxCharactersRange.upperBound)
        #expect(window.2 == ToolCatalog.defaultMaxCharacters)
        let roots = try schemaBounds(ToolCatalog.statusName, "limit")
        #expect(roots.1 == ToolCatalog.rootLimitRange.upperBound)
    }

    @Test("The manifest and the README state no figure the code could change")
    func prosesStateNoFigures() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try String(contentsOf: root.appendingPathComponent("extension/manifest.json"), encoding: .utf8)
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        let figures = [
            ToolCatalog.ocrPagesPerCall, ToolCatalog.barcodePagesPerCall, ToolCatalog.defaultBarcodeLimit,
            ToolCatalog.maxCharactersRange.upperBound, ToolCatalog.defaultMaxCharacters,
            Int(VisionTools.defaultTimeout.components.seconds),
            Int(VisionTools.defaultRecognitionBudget.components.seconds),
        ]
        // A figure may appear only if it is one the code enforces, so none is stale.
        for text in [manifest, readme] {
            for match in text.matches(of: /(\d+) (pages|seconds|characters|codes)/) {
                #expect(figures.contains(Int(match.1) ?? -1), "stale figure: \(match.0)")
            }
        }
    }
}

/// Real recognition over a PDF made here from nothing, inside a directory this suite
/// creates under `$TMPDIR` and removes before it returns.
@Suite("Bounds on synthetic PDFs")
struct SyntheticBoundsTests {

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "apple-vision-mcp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A PDF whose pages each carry one large line of text.
    private func writePDF(pages: Int, to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 600, height: 400)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for number in 1...pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(box)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: CTFontCreateWithName("Helvetica" as CFString, 48, nil),
                .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: "INVENTED PAGE \(number)", attributes: attributes))
            context.textPosition = CGPoint(x: 40, y: 180)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
    }

    private func configuration(_ directory: URL) -> Configuration {
        var configuration = Configuration()
        configuration.readRoots = [directory.path]
        return configuration
    }

    @Test("Recognition stops once the text budget is reached, and the result windows that page")
    func stopsAtTheTextBudget() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("scan.pdf")
        try writePDF(pages: 3, to: file)

        let scoped = try PathScope(configuration: configuration(directory), store: SystemVisionStore())
            .resolve(file.path)
        let content = try await SystemVisionStore().ocr(
            scoped, pages: PageRange(first: 1, last: 3), languages: [], characterBudget: 1,
            deadline: .now + .seconds(60))
        #expect(content.pages.count == 1)
        #expect(content.pageCount == 3)
        #expect(!content.timeBudgetReached)

        let result = await VisionTools(store: SystemVisionStore(), configuration: configuration(directory))
            .handle(.init(name: "vision_ocr", arguments: ["path": .string(file.path), "max_characters": .int(1)]))
        #expect(!result.isError)
        #expect(result.text.contains("Pass character_offset=1 for the rest."))
    }

    @Test("When the time budget is spent the call returns the pages read and says it is partial")
    func partialAtTheTimeBudget() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("scan.pdf")
        try writePDF(pages: 3, to: file)
        let tools = VisionTools(
            store: SystemVisionStore(), configuration: configuration(directory), recognitionBudget: .zero)

        let ocr = await tools.handle(.init(name: "vision_ocr", arguments: ["path": .string(file.path)]))
        #expect(!ocr.isError)
        #expect(ocr.text.contains("Partial: the time limit was reached after 1 pages. Narrow by last_page."))
        #expect(ocr.text.contains("Pages 1–1 of 3. Pass first_page=2 for the next pages."))
        #expect(ocr.text.contains("INVENTED PAGE 1"))

        let barcodes = await tools.handle(
            .init(name: "vision_barcodes", arguments: ["path": .string(file.path)]))
        #expect(barcodes.text.contains("Partial: the time limit was reached after 1 pages."))
        #expect(barcodes.text.contains("Pass first_page=2 for the next pages."))
    }

    @Test("A page range reads exactly those pages")
    func readsTheRequestedPages() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("scan.pdf")
        try writePDF(pages: 3, to: file)
        let tools = VisionTools(store: SystemVisionStore(), configuration: configuration(directory))

        let result = await tools.handle(
            .init(
                name: "vision_ocr",
                arguments: ["path": .string(file.path), "first_page": .int(2), "last_page": .int(2)]))
        #expect(result.text.contains("INVENTED PAGE 2"))
        #expect(!result.text.contains("INVENTED PAGE 1"))
        #expect(!result.text.contains("INVENTED PAGE 3"))
        #expect(result.text.contains("Pages 2–2 of 3. Pass first_page=3 for the next pages."))
    }
}
