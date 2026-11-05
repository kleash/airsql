import Foundation

/// A name prepared for fuzzy matching: `fica` finds `film_category`, `oli` finds `order_lines`.
public struct FuzzyName {
    private let letters: [UInt16]
    /// Where a word of the name starts: its first letter, after `_` and the like, a capital after a small letter.
    private let starts: [Bool]

    private static let separators: Set<UInt16> = Set("_-. /$".utf16)

    public init(_ name: String) {
        let lower = name.lowercased()
        let letters = Array(lower.utf16), original = Array(name.utf16)
        self.letters = letters
        starts = letters.indices.map { index in
            guard index > 0 else { return true }
            if Self.separators.contains(letters[index - 1]) { return true }
            guard original.count == letters.count else { return false }
            return original[index] != letters[index] && original[index - 1] == letters[index - 1]
        }
    }

    /// The words typed, as `score` takes them.
    public static func words(_ text: String) -> [[UInt16]] {
        text.lowercased().split(whereSeparator: \.isWhitespace).map { Array($0.utf16) }
    }

    /// One of the name's words starts with `word`.
    func aWordStarts(with word: [UInt16]) -> Bool {
        letters.indices.contains { starts[$0] && letters[$0...].starts(with: word) }
    }

    /// `word` is, in order, the start of some of the name's words, at least a letter of each: `fica`, `ob` for ORDER BY.
    func isAbbreviated(by word: [UInt16]) -> Bool {
        func from(_ typed: Int, _ place: Int) -> Bool {
            if typed == word.count { return true }
            return (place..<letters.count).contains { start in
                guard starts[start] else { return false }
                var common = 0
                while start + common < letters.count, typed + common < word.count, letters[start + common] == word[typed + common] { common += 1 }
                return common > 0 && (1...common).reversed().contains { from(typed + $0, start + $0) }
            }
        }
        return !word.isEmpty && from(0, 0)
    }

    /// How well the name holds every word's letters in order; nil: it doesn't. Word starts and runs of letters score
    /// more than letters scattered, the whole name most.
    public func score(_ words: [[UInt16]]) -> Int? {
        var total = 0
        for word in words {
            guard let score = score(word) else { return nil }
            total += score
        }
        return total
    }

    private func score(_ word: [UInt16]) -> Int? {
        var next = 0
        for letter in word {
            guard let found = letters[next...].firstIndex(of: letter) else { return nil }
            next = found + 1
        }
        let none = Int.min / 2
        // The best score of the word so far, with its last letter at each place in the name.
        var previous = [Int](repeating: none, count: letters.count)
        for (position, letter) in word.enumerated() {
            var current = [Int](repeating: none, count: letters.count)
            var before = none  // the best of `previous` at least two places back
            for index in letters.indices {
                if index >= 2 { before = max(before, previous[index - 2]) }
                guard letter == letters[index] else { continue }
                let own = starts[index] ? 10 : 1
                if position == 0 {
                    current[index] = own - min(index, 3)
                } else {
                    let run = index > 0 ? previous[index - 1] + 8 : none
                    current[index] = max(run, before - 1) + own
                }
            }
            previous = current
        }
        guard let best = previous.max(), best > none / 2 else { return nil }
        if word == letters { return best + 1_000 }
        return letters.starts(with: word) ? best + 100 : best
    }
}
