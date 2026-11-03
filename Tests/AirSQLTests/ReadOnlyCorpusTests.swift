import AirSQLCore
import Testing

struct ReadOnlyCorpusTests {
    @Test(arguments: AttackCorpus.all, [false, true])
    func attackIsRefused(_ sql: String, noBackslashEscapes: Bool) {
        #expect(ReadOnlyClassifier.classify(sql, noBackslashEscapes: noBackslashEscapes) != .readOnly)
    }

    @Test(arguments: AttackCorpus.againstBackslashEscapes)
    func attackOnBackslashEscapesIsRefused(_ sql: String) {
        #expect(ReadOnlyClassifier.classify(sql, noBackslashEscapes: false) != .readOnly)
    }

    @Test(arguments: AttackCorpus.againstNoBackslashEscapes)
    func attackOnNoBackslashEscapesIsRefused(_ sql: String) {
        #expect(ReadOnlyClassifier.classify(sql, noBackslashEscapes: true) != .readOnly)
    }

    @Test(arguments: ReadCorpus.all, [false, true])
    func readIsAccepted(_ sql: String, noBackslashEscapes: Bool) {
        #expect(ReadOnlyClassifier.classify(sql, noBackslashEscapes: noBackslashEscapes) == .readOnly)
    }
}
