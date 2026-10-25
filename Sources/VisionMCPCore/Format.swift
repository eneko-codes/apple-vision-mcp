import Foundation

/// Plain-text rendering of every tool result.
public struct Format: Sendable {
    public init() {}

    // MARK: Helpers

    static func pad(_ text: String, to width: Int) -> String {
        let shortfall = width - text.count
        return shortfall > 0 ? text + String(repeating: " ", count: shortfall) : text
    }

    static func block(_ rows: [(String, String?)]) -> String {
        let present = rows.compactMap { label, value -> (String, String)? in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return (label, value)
        }
        guard let width = present.map(\.0.count).max() else { return "" }
        let indent = String(repeating: " ", count: width + 3)
        return present.map { label, value in
            let wrapped = value.split(separator: "\n", omittingEmptySubsequences: false)
                .joined(separator: "\n" + indent)
            return "  \(pad(label, to: width)) \(wrapped)"
        }.joined(separator: "\n")
    }

    // MARK: Content

    public func ocr(_ content: OCRContent, path: String) -> String {
        let total = content.pages.reduce(0) { $0 + $1.lines.count }
        var sections = [
            Self.block([
                ("path", path),
                ("source", content.source),
                ("languages", content.recognisedLanguages.joined(separator: ", ")),
                ("lines", "\(total)"),
            ])
        ]
        if total == 0 {
            sections.append(
                """
                Vision recognised no text at all.

                That is a real answer for a photograph with nothing written in it. For a
                document it usually means the scan is too low-contrast or the page is
                rotated; try the file in Preview to see what Vision was given.
                """)
        }
        sections += content.pages.map { page in
            let header = content.pages.count > 1 ? "── page \(page.number) ──\n" : ""
            return header + page.lines.joined(separator: "\n")
        }
        return sections.joined(separator: "\n\n")
    }

    public func barcodes(_ content: BarcodeContent, path: String) -> String {
        let total = content.pages.reduce(0) { $0 + $1.barcodes.count }
        var sections = [
            Self.block([
                ("path", path),
                ("source", content.source),
                ("barcodes", "\(total)"),
            ])
        ]
        if total == 0 {
            sections.append(
                """
                Vision found no barcode or QR code.

                That is a real answer for an image with none in it. If one is there, it may \
                be too small, cropped through its quiet zone, or low-contrast; a larger or \
                cleaner capture is what helps.
                """)
        }
        for page in content.pages where !page.barcodes.isEmpty {
            var lines: [String] = []
            if content.pages.count > 1 {
                lines.append("── page \(page.number) ──")
            }
            lines.append("image \(page.pixelWidth)×\(page.pixelHeight) px")
            for (index, code) in page.barcodes.enumerated() {
                lines.append(
                    Self.block([
                        ("#\(index + 1)", code.symbology),
                        ("payload", code.payload ?? "(bytes that are not text)"),
                        (
                            "box",
                            "x=\(code.x) y=\(code.y) w=\(code.width) h=\(code.height) "
                                + "(px, origin top-left)"
                        ),
                    ]))
            }
            sections.append(lines.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    // MARK: Status

    public func status(probes: [RootProbe], binaryPath: String) -> String {
        let headline =
            probes.isEmpty
            ? "Vision scope: NOTHING configured — this server can see no files."
            : "Vision scope: \(probes.count) read root(s)."

        var text = headline + "\n\n"
        text += Self.block([
            ("binary", binaryPath),
            ("process", "pid \(ProcessInfo.processInfo.processIdentifier)"),
        ])

        text += "\n\nReadable folders:\n"
        if probes.isEmpty {
            text += "  (none configured — nothing is reachable)"
        } else {
            text += probes.map { probe in
                var line = "  \(probe.path) — \(probe.state.rawValue)"
                if let canonical = probe.canonicalPath { line += "\n      resolves to \(canonical)" }
                return line
            }.joined(separator: "\n")
        }

        if probes.contains(where: { $0.state == .notPermitted }) {
            text += """


                One or more roots are configured but macOS refuses them. That is a system
                permission, not this server's allow-list:
                  System Settings → Privacy & Security → Files and Folders → enable the folders
                  under "apple-vision-mcp"
                  (Spanish UI: Ajustes del Sistema → Privacidad y seguridad → Archivos y carpetas)
                Anywhere outside Desktop, Documents and Downloads needs Full Disk Access
                instead, which is granted by hand and never prompts.
                """
        }
        return text
    }
}
