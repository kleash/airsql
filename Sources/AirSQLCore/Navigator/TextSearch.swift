import Foundation

/// Find in Tabs and Files: where a text is, line by line.
public enum TextSearch {
    public struct Match: Equatable, Sendable {
        /// From 1.
        public var line: Int
        /// In UTF-16 units from the start of the text, as a text view counts.
        public var range: NSRange
        /// The line, trimmed.
        public var preview: String
    }

    /// Every place `query` is, without case.
    public static func matches(of query: String, in text: String) -> [Match] {
        guard !query.isEmpty else { return [] }
        let whole = text as NSString
        var found: [Match] = [], from = 0, line = 1, counted = 0
        while from < whole.length {
            let range = whole.range(of: query, options: .caseInsensitive, range: NSRange(location: from, length: whole.length - from))
            guard range.location != NSNotFound else { break }
            let lineRange = whole.lineRange(for: range)
            var scan = counted
            while scan < lineRange.location {
                let next = whole.range(of: "\n", options: .literal, range: NSRange(location: scan, length: lineRange.location - scan))
                guard next.location != NSNotFound else { break }
                line += 1
                scan = next.location + 1
            }
            counted = lineRange.location
            found.append(Match(line: line, range: range, preview: whole.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)))
            from = NSMaxRange(range)
        }
        return found
    }

    /// The .sql files under `folder`, at most `limit`.
    public static func sqlFiles(in folder: URL, limit: Int = 2_000) -> [URL] {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var found: [URL] = []
        while let file = files?.nextObject() as? URL, found.count < limit {
            if file.pathExtension.lowercased() == "sql" { found.append(file) }
        }
        return found
    }
}
