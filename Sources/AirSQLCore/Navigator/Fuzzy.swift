import Foundation

/// A name prepared for fuzzy matching: `fica` finds `film_category`, `oli` finds `order_lines`.
public struct FuzzyName {
    private let letters: [UInt16]
    /// Where a word of the name starts: its first letter, after `_` and the like, a capital after a small letter.
    private let starts: [Bool]

    public init(_ name: String) {
        let lower = name.lowercased()
        let letters = Array(lower.utf16), original = Array(name.utf16)
        self.letters = letters
        let separators: Set<UInt16> = Set("_-. /".utf16)
        starts = letters.indices.map { index in
            guard index > 0 else { return true }
            if separators.contains(letters[index - 1]) { return true }
            guard original.count == letters.count else { return false }
            return original[index] != letters[index] && original[index - 1] == letters[index - 1]
        }
    }

    /// The words typed, as `score` takes them.
    public static func words(_ text: String) -> [[UInt16]] {
        text.lowercased().split(whereSeparator: \.isWhitespace).map { Array($0.utf16) }
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
