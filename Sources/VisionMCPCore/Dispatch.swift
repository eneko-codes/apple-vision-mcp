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

    public init(store: any VisionStore, configuration: Configuration = Configuration()) {
        self.store = store
        self.format = Format()
        self.scope = PathScope(configuration: configuration, store: store)
    }

    public func handle(_ parameters: ToolCall) async -> ToolOutput {
        let started = ContinuousClock.now
        do {
            return ToolOutput(text: try await run(parameters), isError: false)
        } catch let error as ToolError {
            Diagnostics.toolFailed(parameters.name, error: error, since: started)
            return ToolOutput(text: error.message, isError: true)
        } catch {
            Diagnostics.toolFailed(parameters.name, error: error, since: started)
            return ToolOutput(
                text: ToolError.storeFailure(error.localizedDescription).message, isError: true)
        }
    }

    private func run(_ parameters: ToolCall) async throws -> String {
        let arguments = Arguments(parameters.arguments)

        switch parameters.name {
        case ToolCatalog.statusName:
            return status()

        case ToolCatalog.ocrName:
            return try await ocr(arguments)

        case ToolCatalog.barcodesName:
            return try await barcodes(arguments)

        default:
            throw ToolError.badArgument(
                name: "name", reason: "'\(parameters.name)' is not a tool of this server")
        }
    }

    private func status() -> String {
        format.status(probes: scope.probeRoots(), binaryPath: Self.binaryPath)
    }

    private func ocr(_ arguments: Arguments) async throws -> String {
        let path = try scope.resolve(try arguments.requiredString("path"))
        let content = try await store.ocr(
            path, pages: try arguments.pageRange(), languages: try arguments.stringArray("languages"))
        return format.ocr(content, path: path.path)
    }

    private func barcodes(_ arguments: Arguments) async throws -> String {
        let path = try scope.resolve(try arguments.requiredString("path"))
        let content = try await store.barcodes(path, pages: try arguments.pageRange())
        return format.barcodes(content, path: path.path)
    }

    static var binaryPath: String {
        CommandLine.arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? "(unknown)"
    }
}
