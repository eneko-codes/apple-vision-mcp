import Foundation

public enum ToolError: Error, Equatable {
    case noReadRootsConfigured
    case pathOutOfScope(requested: String, resolved: String, readRoots: [String])
    case missingArgument(String)
    case badArgument(name: String, reason: String)
    case notFound(path: String)
    case unreadableImage(path: String)
    case permissionDenied(path: String, detail: String)
    case storeFailure(String)

    public var message: String {
        switch self {
        case .noReadRootsConfigured:
            return """
                This server has no read roots configured, so it can see nothing at all.

                That is the safe default, not a fault: an unconfigured server would
                otherwise start with the whole disk in reach. Name the folders Claude
                may look inside in:
                  Claude Desktop → Settings → Extensions → Vision → Folders Claude may read

                Nothing outside that list can be opened.
                """

        case .pathOutOfScope(let requested, let resolved, let readRoots):
            let scope = readRoots.isEmpty ? "(none configured)" : readRoots.joined(separator: ", ")
            let resolution =
                resolved == requested
                ? "" : "\n\nIt resolves to:\n  \(resolved)\n(symlinks and .. are followed before the check, always)."
            return """
                Path '\(requested)' is outside the scope this extension was configured with.\
                \(resolution)

                Readable folders: \(scope)

                This is not something to work around: the person installing the extension
                chose those folders in its settings, deliberately keeping everything else
                out of reach. Change them in Claude Desktop → Settings → Extensions.
                """

        case .missingArgument(let name):
            return "Missing required argument '\(name)'."

        case .badArgument(let name, let reason):
            return "Argument '\(name)' is not valid: \(reason)"

        case .notFound(let path):
            return "Nothing exists at '\(path)'."

        case .unreadableImage(let path):
            return """
                '\(path)' could not be decoded as an image.

                vision_ocr accepts what ImageIO reads — PNG, JPEG, HEIC, TIFF, GIF, BMP —
                and PDF files, which it renders page by page.
                """

        case .permissionDenied(let path, let detail):
            return """
                macOS refused access to '\(path)': \(detail)

                The path is inside the configured scope, so this is a system permission,
                not this server's allow-list. Two different grants can be missing:

                For Desktop, Documents or Downloads:
                  System Settings → Privacy & Security → Files and Folders → enable the folder
                  under "apple-vision-mcp"
                  (Spanish UI: Ajustes del Sistema → Privacidad y seguridad → Archivos y carpetas)

                For anywhere else — iCloud Drive, an external disk, another user's folder:
                  System Settings → Privacy & Security → Full Disk Access → add and enable
                  "apple-vision-mcp"
                  (Spanish UI: Privacidad y seguridad → Acceso total al disco)

                Then restart Claude Desktop: the permission is resolved when the process
                starts. Full Disk Access has no consent dialog — it is never requested,
                only granted by hand.
                """

        case .storeFailure(let detail):
            return "Vision returned an error: \(detail)"
        }
    }
}
