import Foundation

/// What Go to Row (⌘L) understands: a row number, or column:row where the column is its name or its number on
/// screen, both counted from 1.
public struct GridGoTo: Equatable {
    /// From 0.
    public var row: Int
    /// The column as typed, if one was.
    public var column: String?

    public init?(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let split = text.lastIndex(of: ":")
        let number = split.map { String(text[text.index(after: $0)...]) } ?? text
        guard let row = Int(number.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")), row >= 1 else {
            return nil
        }
        self.row = row - 1
        column = split.map { String(text[..<$0]).trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The display column `column` names among `names` (shown in that order): its number, else its name (any case).
    public func columnIndex(in names: [String]) -> Int? {
        guard let column else { return nil }
        if let number = Int(column), names.indices.contains(number - 1) { return number - 1 }
        return names.firstIndex(of: column) ?? names.firstIndex { $0.caseInsensitiveCompare(column) == .orderedSame }
    }
}
