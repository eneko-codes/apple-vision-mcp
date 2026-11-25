import Foundation

/// The seam between the tool layer and the real disk.
///
/// Everything above this protocol is exercised by the tests against an in-memory scope;
/// everything below it can only be verified against a real image or PDF. Keeping the
/// boundary this thin is what makes the untested surface small enough to check by hand.
///
/// Every path-taking method takes a `ScopedPath`, which cannot be constructed without
/// passing the allow-list check. `canonicalise` is the one exception: it is the step
/// that *feeds* the check, and it reads nothing but the shape of the path.
public protocol VisionStore: Sendable {

    // MARK: Resolution

    /// Expands `~`, removes `.`/`..`, and resolves every symlink in the path.
    func canonicalise(_ path: String) throws -> CanonicalPath

    // MARK: Status

    /// Whether the root is there and this process may actually look inside it.
    func probe(_ path: String) -> RootState

    // MARK: Reads

    /// Reads `pages` in order and stops early, with what it has, when the text read so far
    /// reaches `characterBudget` or when `deadline` has passed (after at least one page, so
    /// every call makes progress). A range that runs past the end of the file is cut to it.
    func ocr(
        _ path: ScopedPath, pages: PageRange, languages: [String], characterBudget: Int,
        deadline: ContinuousClock.Instant
    ) async throws -> OCRContent

    /// As `ocr`, without the text budget.
    func barcodes(
        _ path: ScopedPath, pages: PageRange, deadline: ContinuousClock.Instant
    ) async throws -> BarcodeContent
}
