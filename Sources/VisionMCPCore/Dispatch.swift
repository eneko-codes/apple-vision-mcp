import Foundation
import MCP

/// Routes a `tools/call` to the store and renders the answer.
///
/// Never touches the disk directly — everything goes through `VisionStore`, which is
/// what lets the tests drive every branch below against an in-memory scope with no real
/// files and no TCC grant.
///
/// Every path argument, without exception, is turned into a `ScopedPath` by
/// `PathScope.resolve` before it is used. There is no other way to obtain one, so a tool
/// added later cannot forget the check: it will not compile.
public struct VisionTools: Sendable {
    private let store: any VisionStore
    private let scope: PathScope
    private let format: Format

    public init(store: any VisionStore, configuration: Configuration = Configuration()) {
        self.store = store
        self.format = Format()
        self.scope = PathScope(configuration: configuration, store: store)
    }

    public func handle(_ parameters: CallTool.Parameters) async -> CallTool.Result {
        do {
            let text = try await run(parameters)
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch let error as ToolError {
            return .init(
                content: [.text(text: error.message, annotations: nil, _meta: nil)], isError: true)
        } catch {
            return .init(
                content: [
                    .text(
                        text: ToolError.storeFailure(error.localizedDescription).message,
                        annotations: nil, _meta: nil)
                ], isError: true)
        }
    }

    private func run(_ parameters: CallTool.Parameters) async throws -> String {
        let arguments = Arguments(parameters.arguments)

        switch parameters.name {
        case ToolCatalog.statusName:
            return status()

        case ToolCatalog.ocrName:
            return try await ocr(arguments)

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

    static var binaryPath: String {
        CommandLine.arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? "(unknown)"
    }
}
