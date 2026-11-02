import AirSQLCore
import Testing

struct ReadOnlyCorpusTests {
    @Test(arguments: AttackCorpus.all)
    func attackIsRefused(_ sql: String) {
        #expect(ReadOnlyClassifier.classify(sql) != .readOnly)
    }

    @Test(arguments: ReadCorpus.all)
    func readIsAccepted(_ sql: String) {
        #expect(ReadOnlyClassifier.classify(sql) == .readOnly)
    }
}
