import CMariaDB
import Testing
@testable import AirSQLCore

struct ResultStoreTests {
    @Test func keepsBytesNullsAndEmptyValues() {
        let store = ResultStore(columns: [ResultStore.Column(name: "id", type: MYSQL_TYPE_LONG),
                                          ResultStore.Column(name: "note", type: MYSQL_TYPE_VAR_STRING)])
        store.append([Array("1".utf8), Array("first".utf8)])
        store.append([Array("2".utf8), nil])
        store.append([Array("3".utf8), []])
        store.append([Array("4".utf8), Array("😀 ünï".utf8)])
        store.finish()
        #expect(store.rowCount == 4)
        #expect(store.string(0, 1) == "first")
        #expect(store.isNull(1, 1) && store.string(1, 1) == nil && store.display(1, 1) == nil)
        #expect(!store.isNull(2, 1) && store.string(2, 1) == "")
        #expect(store.string(3, 1) == "😀 ünï")
        #expect(store.bytes(3, 0) == Array("4".utf8))
    }

    @Test func showsBinaryAsHexAndBitsAsBits() {
        let store = ResultStore(columns: [ResultStore.Column(name: "b", type: MYSQL_TYPE_BLOB, charset: 63),
                                          ResultStore.Column(name: "bit", type: MYSQL_TYPE_BIT, charset: 63, length: 10),
                                          ResultStore.Column(name: "n", type: MYSQL_TYPE_LONGLONG, charset: 63)])
        store.append([[0x00, 0xAB, 0x27], [0x01, 0x05], Array("42".utf8)])
        store.append([Array(repeating: 0xFF, count: 300), [0x00, 0x00], Array("7".utf8)])
        #expect(store.display(0, 0) == "0x00AB27")
        #expect(store.display(0, 1) == "0100000101")
        #expect(store.display(1, 1) == "0000000000")
        #expect(store.display(0, 2) == "42")  // numbers carry the binary charset but are text
        #expect(store.display(1, 0) == "0x" + String(repeating: "FF", count: 256) + "…")
    }

    /// grid-spec §8: a 1,000,000 × 10 result of short values is held in under 150 MB.
    @Test func millionRowsOfShortValuesStaySmall() {
        let columns = (0..<10).map { ResultStore.Column(name: "c\($0)", type: MYSQL_TYPE_VAR_STRING) }
        let store = ResultStore(columns: columns)
        let cells: [[UInt8]?] = (0..<10).map { $0 == 3 ? nil : Array("v\($0)-12345".utf8) }
        for _ in 0..<1_000_000 { store.append(cells) }
        store.finish()
        #expect(store.rowCount == 1_000_000)
        #expect(store.string(999_999, 9) == "v9-12345")
        #expect(store.isNull(500_000, 3))
        #expect(store.byteCount < 150 << 20, "\(store.byteCount >> 20) MB")
    }

    @Test func refusesRowsBeyondItsByteLimit() {
        let store = ResultStore(columns: [ResultStore.Column(name: "blob", type: MYSQL_TYPE_LONG_BLOB, charset: 63)],
                                byteLimit: 1000)
        let big = [UInt8](repeating: 1, count: 501)
        #expect(store.append([big]))
        #expect(!store.append([big]))
        #expect(store.rowCount == 1)
    }
}
