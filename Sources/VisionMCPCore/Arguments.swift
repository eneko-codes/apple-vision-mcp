import Foundation

/// Typed access to a `tools/call` argument bag.
///
/// A class, not a struct, so that reading a number can also record that it was moved into
/// its range without every reader having to be `mutating`. One instance serves one call and
/// never leaves it. The tool hands `notices` to `Format`, which puts them before the data.
public final class Arguments {
    private let values: [String: Value]

    /// One sentence for each number that was moved into its range, in the order read.
    public private(set) var notices: [String] = []

    public init(_ values: [String: Value]?) {
        self.values = values ?? [:]
    }

    /// Refuses an argument the schema does not list. Without this, a call that still uses
    /// a name the tool no longer has would run as if the argument had not been given.
    public func allowOnly(_ allowed: [String]) throws {
        guard let unknown = values.keys.sorted().first(where: { !allowed.contains($0) }) else {
            return
        }
        throw ToolError.badArgument(
            name: ToolStandard.echo(unknown),
            reason: "this tool has no such argument. Allowed: " + allowed.sorted().joined(separator: ", "))
    }

    /// `nil` when the argument is absent or null, which mean the same: not given.
    private func given(_ name: String) -> Value? {
        guard let raw = values[name], !raw.isNull else { return nil }
        return raw
    }

    private func wholeNumber(_ name: String) throws -> Int? {
        guard let raw = given(name) else { return nil }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "a whole number was expected")
        }
        return number
    }

    public func requiredString(_ name: String) throws -> String {
        guard let raw = given(name) else { throw ToolError.missingArgument(name) }
        guard let text = raw.stringValue else {
            throw ToolError.badArgument(name: name, reason: "text was expected")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError.badArgument(name: name, reason: "it is empty")
        }
        return trimmed
    }

    public func stringArray(_ name: String) throws -> [String] {
        guard let raw = given(name) else { return [] }
        guard let entries = raw.arrayValue else {
            throw ToolError.badArgument(name: name, reason: "an array of strings was expected")
        }
        return try entries.map { entry in
            guard let text = entry.stringValue else {
                throw ToolError.badArgument(name: name, reason: "an array of strings was expected")
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    /// A quantity or a position: outside its range it is moved to the nearest allowed
    /// value, and `notices` gains the sentence that says which value was used.
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws -> Int {
        guard let number = try wholeNumber(name) else { return fallback }
        return ToolStandard.clamp(number, to: range, argument: name, notices: &notices)
    }

    /// The `limit` and `offset` of a listing, read the same way by every tool that pages.
    public func page(defaultLimit: Int, limits: ClosedRange<Int>) throws -> (limit: Int, offset: Int) {
        (
            try int("limit", default: defaultLimit, in: limits),
            try int("offset", default: 0, in: ToolCatalog.offsetRange)
        )
    }

    /// `first_page` and `last_page`, numbered from 1, both included. At most
    /// `longest` pages are read from `first_page`: a `last_page` beyond that is moved and
    /// the result says which one was used, and with no `last_page` the range is the
    /// longest one. A `last_page` before `first_page` is refused, not moved, because
    /// nothing says which of the two the caller got wrong.
    public func pageRange(longest: Int) throws -> PageRange {
        let first = try int("first_page", default: 1, in: ToolCatalog.pageNumberRange)
        let widest = first + longest - 1
        guard let asked = try wholeNumber("last_page") else {
            return PageRange(first: first, last: widest)
        }
        guard asked >= first else {
            throw ToolError.badArgument(
                name: "last_page", reason: "it is \(asked), before first_page (\(first))")
        }
        guard asked <= widest else {
            notices.append(
                Notice.adjusted(argument: "last_page", asked: asked, range: first...widest, used: widest))
            return PageRange(first: first, last: widest)
        }
        return PageRange(first: first, last: asked)
    }
}
