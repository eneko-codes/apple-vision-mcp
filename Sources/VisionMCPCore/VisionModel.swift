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
