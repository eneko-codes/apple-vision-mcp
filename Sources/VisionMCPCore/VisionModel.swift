import Foundation

/// Value types crossing the store seam. Nothing here imports a filesystem, PDFKit or
/// Vision API, which is what lets the tests build a scope in memory.

// MARK: - Paths

/// The result of canonicalising a raw path string, before any scope check.
public struct CanonicalPath: Sendable, Equatable {
    public let path: String
    public let exists: Bool

    public init(path: String, exists: Bool) {
        self.path = path
        self.exists = exists
    }
}

// `ScopedPath` deliberately lives in PathScope.swift instead: its initialiser is
// fileprivate, so that file is the only place in the module able to mint one.

/// An inclusive, 1-based page range, for a PDF being rendered page by page. PDF page
/// numbers are what a person reads off the page, not an array index, and the off-by-one
/// is worth spending a type on.
public struct PageRange: Sendable, Equatable {
    public let first: Int
    public let last: Int

    public init(first: Int, last: Int) {
        self.first = first
        self.last = last
    }

    public func clamped(to pageCount: Int) -> PageRange {
        PageRange(
            first: Swift.max(1, Swift.min(first, pageCount)),
            last: Swift.max(1, Swift.min(last, pageCount)))
    }
}

// MARK: - Content

public struct OCRContent: Sendable, Equatable {
    public struct Page: Sendable, Equatable {
        public let number: Int
        public let lines: [String]

        public init(number: Int, lines: [String]) {
            self.number = number
            self.lines = lines
        }
    }

    public let pages: [Page]
    /// "image" or "pdf", so the answer says what Vision was actually pointed at.
    public let source: String
    public let recognisedLanguages: [String]

    public init(pages: [Page], source: String, recognisedLanguages: [String]) {
        self.pages = pages
        self.source = source
        self.recognisedLanguages = recognisedLanguages
    }
}

public struct BarcodeContent: Sendable, Equatable {
    public struct Barcode: Sendable, Equatable {
        /// Vision's symbology name without its `VNBarcodeSymbology` prefix: "QR",
        /// "Code128", "EAN13"…
        public let symbology: String
        /// Nil when the code carries bytes that are not text, which is a real answer and
        /// not a failure to decode.
        public let payload: String?
        /// Pixels of the image Vision was given, origin top-left. Vision's own boxes are
        /// normalised with the origin bottom-left, which nobody reading a result expects.
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int

        public init(
            symbology: String, payload: String?, x: Int, y: Int, width: Int, height: Int
        ) {
            self.symbology = symbology
            self.payload = payload
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public struct Page: Sendable, Equatable {
        public let number: Int
        /// The bitmap's size, so the boxes can be read against something.
        public let pixelWidth: Int
        public let pixelHeight: Int
        public let barcodes: [Barcode]

        public init(number: Int, pixelWidth: Int, pixelHeight: Int, barcodes: [Barcode]) {
            self.number = number
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.barcodes = barcodes
        }
    }

    public let pages: [Page]
    /// "image" or "pdf", as for `OCRContent`.
    public let source: String

    public init(pages: [Page], source: String) {
        self.pages = pages
        self.source = source
    }
}

// MARK: - Status

/// What one configured root is actually worth right now. There is no API that asks TCC
/// "may I read this folder?", so the only honest answer comes from trying.
public enum RootState: String, Sendable, Equatable {
    case reachable
    case missing
    /// The path is there and macOS refused. This is the TCC denial, and the one the
    /// status message has to explain how to fix.
    case notPermitted
}

public struct RootProbe: Sendable, Equatable {
    public let path: String
    public let state: RootState
    /// Set when the configured root does not canonicalise to itself — a symlinked root
    /// silently governs a different subtree than the one that was typed.
    public let canonicalPath: String?

    public init(path: String, state: RootState, canonicalPath: String? = nil) {
        self.path = path
        self.state = state
        self.canonicalPath = canonicalPath
    }
}
