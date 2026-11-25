import Foundation

/// Routes a `tools/call` to the store and renders the answer.
///
/// Never touches the disk directly — everything goes through `VisionStore`, which is
/// what lets the tests drive every branch below against an in-memory scope with no real
/// files and no TCC grant.
///
/// Every path argument, without exception, is turned into a `ScopedPath` by
/// `PathScope.resolve` before it is used. There is no other way to obtain one, so a tool
/// added later cannot forget the check: it will not compile.
public struct VisionTools: ToolHandler {
    private let store: any VisionStore
    private let scope: PathScope
    private let format: Format
    private let timeout: Duration
    private let recognitionBudget: Duration

    /// The longest a call may take before it is abandoned and answered with an error. It
    /// sits well inside `ToolStandard.timeLimit`, so the answer is ours and not the
    /// client's generic "no result".
    public static let defaultTimeout = Duration.seconds(150)

    /// After this long no further page is started and the call returns what it has. It
    /// leaves `defaultTimeout` minus this for the page already under way, which cannot be
    /// interrupted.
    public static let defaultRecognitionBudget = Duration.seconds(90)

    public init(
        store: any VisionStore, configuration: Configuration = Configuration(),
        timeout: Duration = VisionTools.defaultTimeout,
        recognitionBudget: Duration = VisionTools.defaultRecognitionBudget
    ) {
        self.store = store
        self.format = Format()
        self.scope = PathScope(configuration: configuration, store: store)
        self.timeout = timeout
        self.recognitionBudget = recognitionBudget
    }

    public func handle(_ parameters: ToolCall) async -> ToolOutput {
        let started = ContinuousClock.now
        // The timer is not a child of the work: a Vision request that is running cannot be
        // cancelled, and waiting for it would hold the answer past the deadline.
        let outcome = await Deadline.run(within: timeout) {
            do {
                return Result<String, any Error>.success(try await run(parameters))
            } catch {
                return .failure(error)
            }
        }
        switch outcome {
        case .success(let text)?:
            return ToolOutput(text: text, isError: false)
        case .failure(let error)?:
            return failure(error, tool: parameters.name, since: started)
        case nil:
            return failure(
                ToolError.timedOut(seconds: Int(timeout.components.seconds)),
                tool: parameters.name, since: started)
        }
    }

    private func failure(
        _ error: any Error, tool: String, since started: ContinuousClock.Instant
    ) -> ToolOutput {
        Diagnostics.toolFailed(tool, error: error, since: started)
        if let error = error as? ToolError {
            return ToolOutput(text: error.message, isError: true)
        }
        return ToolOutput(
            text: ToolError.storeFailure(error.localizedDescription).message, isError: true)
    }

    private func run(_ parameters: ToolCall) async throws -> String {
        let arguments = Arguments(parameters.arguments)

        switch parameters.name {
        case ToolCatalog.statusName:
            return try status(arguments)

        case ToolCatalog.ocrName:
            return try await ocr(arguments)

        case ToolCatalog.barcodesName:
            return try await barcodes(arguments)

        default:
            throw ToolError.unknownTool(parameters.name)
        }
    }

    private func status(_ arguments: Arguments) throws -> String {
        try arguments.allowOnly(["limit", "offset"])
        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultRootLimit, limits: ToolCatalog.rootLimitRange)
        let total = scope.configuredRootCount
        let probes = scope.probeRoots(offset: page.offset, limit: page.limit)
        return ToolStandard.fitting(page.limit) { size in
            let shown = Array(probes.prefix(size))
            let position = Notice.page(
                offset: page.offset, count: shown.count, total: total, things: "read roots")
            return ToolStandard.withNotices(
                arguments.notices + [position].compactMap { $0 },
                format.status(probes: shown, total: total, binaryPath: Self.binaryPath))
        }
    }

    private func ocr(_ arguments: Arguments) async throws -> String {
        try arguments.allowOnly(
            ["path", "languages", "first_page", "last_page", "character_offset", "max_characters"])
        let path = try scope.resolve(try arguments.requiredString("path"))
        let languages = try arguments.stringArray("languages")
        let pages = try arguments.pageRange(longest: ToolCatalog.ocrPagesPerCall)
        let characterOffset = try arguments.int(
            "character_offset", default: 0, in: ToolCatalog.characterOffsetRange)
        let maxCharacters = try arguments.int(
            "max_characters", default: ToolCatalog.defaultMaxCharacters,
            in: ToolCatalog.maxCharactersRange)

        let content = try await store.ocr(
            path, pages: pages, languages: languages, characterBudget: maxCharacters,
            deadline: .now + recognitionBudget)
        return format.ocr(
            content, path: path.path, firstPage: pages.first, characterOffset: characterOffset,
            maxCharacters: maxCharacters, notices: arguments.notices)
    }

    private func barcodes(_ arguments: Arguments) async throws -> String {
        try arguments.allowOnly(["path", "first_page", "last_page", "limit", "offset"])
        let path = try scope.resolve(try arguments.requiredString("path"))
        let pages = try arguments.pageRange(longest: ToolCatalog.barcodePagesPerCall)
        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultBarcodeLimit, limits: ToolCatalog.barcodeLimitRange)

        let content = try await store.barcodes(
            path, pages: pages, deadline: .now + recognitionBudget)
        var notices = arguments.notices
        if content.timeBudgetReached {
            notices.append(
                Notice.partial(after: content.pages.count, things: "pages", narrowBy: "last_page"))
        }
        notices += [
            Format.pagesNotice(
                first: pages.first, count: content.pages.count, total: content.pageCount)
        ].compactMap { $0 }

        let rows = Format.barcodeRows(content)
        return ToolStandard.page(
            of: rows, limit: page.limit, offset: page.offset, things: "codes", notices: notices
        ) { shown in
            format.barcodes(
                content, shown: shown, first: page.offset, total: rows.count, path: path.path)
        }
    }

    static var binaryPath: String {
        CommandLine.arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? "(unknown)"
    }
}
