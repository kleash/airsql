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

/// What a cell's text can open or show beside another.
public enum GridLink {
    /// The web address a whole cell holds; other schemes (file, a custom app's) aren't for a click on data.
    public static func url(_ text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()), url.host?.isEmpty == false else { return nil }
        return url
    }

    /// `second` against `first` line by line: "  " for a line in both, "− " for one only in the first, "+ " only in the second.
    public static func lineDifference(_ first: String, _ second: String) -> String {
        let old = first.components(separatedBy: .newlines), new = second.components(separatedBy: .newlines)
        let difference = new.difference(from: old)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var lines: [String] = [], left = 0, right = 0
        while left < old.count || right < new.count {
            if left < old.count, removed.contains(left) {
                lines.append("− " + old[left])
                left += 1
            } else if right < new.count, inserted.contains(right) {
                lines.append("+ " + new[right])
                right += 1
            } else {
                lines.append("  " + new[right])
                left += 1
                right += 1
            }
        }
        return lines.joined(separator: "\n")
    }
}
