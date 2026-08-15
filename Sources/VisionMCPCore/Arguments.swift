import Foundation
import MCP

/// Typed access to a `tools/call` argument bag.
public struct Arguments {
    private let values: [String: Value]

    public init(_ values: [String: Value]?) {
        self.values = values ?? [:]
    }

    // MARK: Scalars

    public func requiredString(_ name: String) throws -> String {
        guard let raw = values[name]?.stringValue else { throw ToolError.missingArgument(name) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError.badArgument(name: name, reason: "it is empty")
        }
        return trimmed
    }

    public func stringArray(_ name: String) throws -> [String] {
        guard let raw = values[name] else { return [] }
        if case .null = raw { return [] }
        // A single string where an array is expected is a common and harmless slip.
        if let single = raw.stringValue { return [single] }
        guard let entries = raw.arrayValue else {
            throw ToolError.badArgument(name: name, reason: "an array of strings was expected")
        }
        return entries.compactMap(\.stringValue)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// An integer the caller may legitimately omit, where the absence means "no bound"
    /// rather than a default value.
    public func optionalInt(_ name: String) throws -> Int? {
        guard let raw = values[name] else { return nil }
        if case .null = raw { return nil }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "an integer was expected")
        }
        return number
    }

    // MARK: Pages

    /// `first_page`/`last_page`, 1-based and inclusive. Returns nil when neither was
    /// given, which the tools read as "the whole document".
    public func pageRange() throws -> PageRange? {
        let first = try optionalInt("first_page")
        let last = try optionalInt("last_page")
        guard first != nil || last != nil else { return nil }
        let lower = Swift.max(first ?? 1, 1)
        let upper = Swift.max(last ?? Int.max, lower)
        guard upper >= lower else {
            throw ToolError.badArgument(
                name: "last_page", reason: "it is before 'first_page'")
        }
        return PageRange(first: lower, last: upper)
    }
}
