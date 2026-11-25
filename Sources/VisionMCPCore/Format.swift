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

    // MARK: Notices

    /// Which pages of the file a result holds. `Notice` has no form for pages, so this
    /// follows `Notice.page` with `first_page` in place of `offset`. `nil` when the result
    /// starts at the first page and holds the rest of the file.
    static func pagesNotice(first: Int, count: Int, total: Int) -> String? {
        let last = first + count - 1
        guard first > 1 || last < total else { return nil }
        guard count > 0 else {
            return "Pages 0 of \(total): first_page=\(first) is past the end. That is all."
        }
        let shown = "Pages \(first)–\(last) of \(total)."
        return last < total
            ? "\(shown) Pass first_page=\(last + 1) for the next pages." : "\(shown) That is all."
    }

    // MARK: Content

    /// `notices` are what reading the arguments left to say. The pages that fit are chosen
    /// here, from what was read, and the notice that says which pages those are is built
    /// from the choice, so it stays true when `ToolStandard.fitting` halves the size.
    public func ocr(
        _ content: OCRContent, path: String, firstPage: Int, characterOffset: Int,
        maxCharacters: Int, notices: [String]
    ) -> String {
        ToolStandard.fitting(maxCharacters) { size in
            var shown: [OCRContent.Page] = []
            var firstText: String?
            var moreText = false
            var found = notices
            if let head = content.pages.first {
                shown = [head]
                if characterOffset > 0 || head.text.count > size {
                    // One page alone: its own window, and only it.
                    let label = "Page \(head.number), read with first_page=\(head.number)"
                    let window = ToolStandard.window(
                        of: head.text, characterOffset: characterOffset, maxCharacters: size,
                        label: label)
                    firstText = window.text
                    found += [window.notice].compactMap { $0 }
                    moreText = window.notice?.contains("Pass character_offset=") == true
                } else {
                    var used = head.text.count
                    for page in content.pages.dropFirst() {
                        let width = page.text.count
                        guard used + width <= size else { break }
                        used += width
                        shown.append(page)
                    }
                }
            }
            if content.timeBudgetReached {
                found.append(Notice.partial(after: content.pages.count, things: "pages", narrowBy: "last_page"))
            }
            // While text of the first page remains, "that is all" about pages would mislead:
            // the last window of the page carries the pages notice.
            if !moreText {
                found += [Self.pagesNotice(first: firstPage, count: shown.count, total: content.pageCount)]
                    .compactMap { $0 }
            }

            let lineCount = shown.reduce(0) { $0 + $1.lines.count }
            var sections = [
                Self.block([
                    ("path", path),
                    ("source", content.source),
                    ("languages", content.recognisedLanguages.joined(separator: ", ")),
                    ("lines", "\(lineCount)"),
                ])
            ]
            if !shown.isEmpty, lineCount == 0, shown.allSatisfy(\.rendered) {
                sections.append(
                    """
                    Vision recognised no text at all.

                    That is a real answer for a photograph with nothing written in it. For a
                    document it usually means the scan is too low-contrast or the page is
                    rotated; try the file in Preview to see what Vision was given.
                    """)
            }
            for (index, page) in shown.enumerated() {
                let header = content.pageCount > 1 ? "── page \(page.number) ──\n" : ""
                sections.append(header + (index == 0 ? firstText ?? page.text : page.text))
            }
            return ToolStandard.withNotices(found, sections.joined(separator: "\n\n"))
        }
    }

    /// One code with the page it was found on.
    public struct BarcodeRow: Sendable, Equatable {
        public let page: Int
        public let pixelWidth: Int
        public let pixelHeight: Int
        public let code: BarcodeContent.Barcode
    }

    /// Every code of the pages read, in the order the tool states: by page, then top to
    /// bottom, then left to right, with the rest of the code as tie-breakers so that two
    /// calls split the same list at the same place.
    public static func barcodeRows(_ content: BarcodeContent) -> [BarcodeRow] {
        content.pages.flatMap { page in
            page.barcodes.map {
                BarcodeRow(page: page.number, pixelWidth: page.pixelWidth, pixelHeight: page.pixelHeight, code: $0)
            }
        }.sorted { lhs, rhs in
            func key(_ row: BarcodeRow) -> [String] {
                [
                    String(format: "%09d", row.page), String(format: "%09d", row.code.y),
                    String(format: "%09d", row.code.x), String(format: "%09d", row.code.width),
                    String(format: "%09d", row.code.height), row.code.symbology, row.code.payload ?? "",
                ]
            }
            return key(lhs).lexicographicallyPrecedes(key(rhs))
        }
    }

    /// `shown` is one page of `rows`, which starts at index `first` (from 0) of `total`
    /// codes found on the pages read.
    public func barcodes(
        _ content: BarcodeContent, shown: [BarcodeRow], first: Int, total: Int, path: String
    ) -> String {
        var sections = [
            Self.block([
                ("path", path),
                ("source", content.source),
                ("barcodes", "\(total)"),
            ])
        ]
        let unreadable = content.pages.filter { !$0.rendered }.map { String($0.number) }
        if !unreadable.isEmpty {
            sections.append("Pages that could not be rendered: \(unreadable.joined(separator: ", ")).")
        }
        if total == 0, !content.pages.isEmpty, unreadable.isEmpty {
            sections.append(
                """
                Vision found no barcode or QR code.

                That is a real answer for an image with none in it. If one is there, it may \
                be too small, cropped through its quiet zone, or low-contrast; a larger or \
                cleaner capture is what helps.
                """)
        }
        var lines: [String] = []
        var currentPage: Int?
        for (index, row) in shown.enumerated() {
            if row.page != currentPage {
                if !lines.isEmpty { sections.append(lines.joined(separator: "\n")) }
                lines = []
                currentPage = row.page
                if content.pageCount > 1 { lines.append("── page \(row.page) ──") }
                lines.append("image \(row.pixelWidth)×\(row.pixelHeight) px")
            }
            lines.append(
                Self.block([
                    ("#\(first + index + 1)", row.code.symbology),
                    ("payload", row.code.payload ?? "(bytes that are not text)"),
                    (
                        "box",
                        "x=\(row.code.x) y=\(row.code.y) w=\(row.code.width) h=\(row.code.height) "
                            + "(px, origin top-left)"
                    ),
                ]))
        }
        if !lines.isEmpty { sections.append(lines.joined(separator: "\n")) }
        return sections.joined(separator: "\n\n")
    }

    // MARK: Status

    /// `probes` is one page of the `total` configured roots.
    public func status(probes: [RootProbe], total: Int, binaryPath: String) -> String {
        let headline =
            total == 0
            ? "Vision scope: NOTHING configured — this server can see no files."
            : "Vision scope: \(total) read root(s)."

        var text = headline + "\n\n"
        text += Self.block([
            ("binary", binaryPath),
            ("process", "pid \(ProcessInfo.processInfo.processIdentifier)"),
        ])

        text += "\n\nReadable folders:\n"
        if total == 0 {
            text += "  (none configured — nothing is reachable)"
        } else if probes.isEmpty {
            text += "  (none on this page)"
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
