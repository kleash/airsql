@testable import AirSQLCore
import Foundation
import Testing

private func doc(_ fields: [(String, BSONValue)]) -> BSONDocument { BSONDocument(fields.map { (key: $0.0, value: $0.1) }) }
private func bytes(_ fields: [(String, BSONValue)]) -> [UInt8] { try! doc(fields).bytes() }
private func names(_ source: MongoDocumentSource) -> [String] { source.columns.map(\.name) }

@Suite struct MongoDocumentSourceTests {
    @Test func columnsFollowFirstAppearanceWithIdFirstAndLateKeys() {
        let source = MongoDocumentSource()
        let changed = source.append([bytes([("name", .string("a")), ("_id", .int32(1))]),
                                     bytes([("_id", .int32(2)), ("age", .int32(3))])])
        #expect(changed)
        #expect(names(source) == ["_id", "name", "age"])
        #expect(source.columns[0].isKey && source.columns[0].marks.contains(.primary))
        #expect(!source.append([bytes([("_id", .int32(3)), ("name", .string("c"))])]))
        #expect(source.append([bytes([("_id", .int32(4)), ("late", .bool(true))])]))
        #expect(names(source) == ["_id", "name", "age", "late"])
        #expect(source.rowCount == 4)
        #expect(source.cell(3, 3) == .text("true"))
    }

    @Test func subDocumentsExpandAndCollapse() {
        let source = MongoDocumentSource()
        source.append([bytes([("_id", .int32(1)), ("a", .document(doc([("x", .int32(1)), ("y", .document(doc([("z", .string("q"))])))]))),
                              ("tags", .array([.string("t1"), .string("t2")]))])])
        #expect(names(source) == ["_id", "a", "tags"])
        #expect(source.columns[1].kind == .json && source.canExpand(1))
        #expect(!source.canExpand(2))  // arrays stay one cell
        #expect(source.cell(0, 2) == .text("[ \"t1\", \"t2\" ]"))
        #expect(source.setExpanded(["a"], true))
        #expect(names(source) == ["_id", "a.x", "a.y", "tags"])
        #expect(source.paths[2] == ["a", "y"] && source.cell(0, 1) == .text("1"))
        source.setExpanded(["a", "y"], true)
        #expect(names(source) == ["_id", "a.x", "a.y.z", "tags"])
        source.setExpanded(["a"], false)
        #expect(names(source) == ["_id", "a", "tags"])
        source.setExpanded(["a"], true)  // what was expanded under it comes back
        #expect(names(source) == ["_id", "a.x", "a.y.z", "tags"])
        #expect(source.isExpanded(["a", "y"]))
    }

    @Test func missingDiffersFromNull() {
        let source = MongoDocumentSource()
        source.append([bytes([("_id", .int32(1)), ("v", .null)]), bytes([("_id", .int32(2))]),
                       bytes([("_id", .int32(3)), ("v", .string(""))])])
        #expect(source.cell(0, 1) == .null && source.note(0, 1) == nil && source.value(0, 1) == nil)
        #expect(source.cell(1, 1) == .text("") && source.note(1, 1)?.hasPrefix("Missing") == true)
        #expect(source.bsonValue(1, 1) == nil && source.bsonValue(0, 1) == .null)
        #expect(source.cell(2, 1) == .text("\"\"") && source.note(2, 1) == nil)
        #expect(source.columns[1].marks.contains(.nullable))
        #expect(source.columns[1].comment == "missing in 1 of 3 documents")
    }

    @Test func mixedTypesAreBadgedAndKindsMapped() {
        let source = MongoDocumentSource()
        source.append([bytes([("_id", .objectId(BSONObjectId(hex: "0123456789abcdef01234567")!)), ("m", .int32(1)), ("n", .int64(5)),
                              ("d", .datetime(0)), ("b", .binary(subtype: 0, data: Data([1])))]),
                       bytes([("_id", .int32(9)), ("m", .string("x")), ("n", .double(1.5)), ("d", .null)]),
                       bytes([("m", .string("y")), ("n", .decimal128(BSONDecimal128("2.5")!))])])
        let byName = Dictionary(uniqueKeysWithValues: source.columns.map { ($0.name, $0) })
        #expect(byName["m"]?.type == "mixed: string, int" && byName["m"]?.kind == .text)
        #expect(byName["n"]?.type.hasPrefix("mixed: ") == true && byName["n"]?.kind == .number)
        #expect(byName["d"]?.type == "date" && byName["d"]?.kind == .date)
        #expect(byName["b"]?.kind == .binary)
        #expect(byName["_id"]?.type == "mixed: objectId, int")
        // Numbers reach the status bar as plain digits; cells keep shell form.
        #expect(source.value(0, 2) == "5" && source.cell(0, 2) == .text("NumberLong(5)"))
        #expect(GridAggregate((0..<3).map { source.value($0, 2) }).sum == 9)
    }

    @Test func onlyCellsAskedForAreDecoded() {
        let source = MongoDocumentSource()
        source.append((0..<1_000).map { bytes([("_id", .int32(Int32($0))), ("v", .string("value \($0)"))]) })
        #expect(source.decodes == 0)
        #expect(source.cell(500, 1) == .text("\"value 500\""))
        _ = source.cell(500, 1)  // cached
        #expect(source.decodes == 1)
        #expect(source.document(7)?["v"] == .string("value 7"))
    }

    @Test func aSixteenMegabyteDocumentIsCutAndFast() throws {
        let page = [bytes([("_id", .int32(1)), ("big", .string(String(repeating: "x", count: 16_000_000))), ("small", .int32(2))])]
        let source = MongoDocumentSource()
        let elapsed = ContinuousClock().measure {
            source.append(page)
            #expect(source.cell(0, 2) == .text("2"))
            guard case .text(let shown) = source.cell(0, 1) else { Issue.record("not text"); return }
            #expect(shown.count == MongoDocumentSource.shownLimit + 1 && shown.hasSuffix("…"))
        }
        #expect(elapsed < .seconds(10))  // a debug build; most of it is checking the 16 MB string the cell shows
    }

    @Test func aHundredThousandSmallDocumentsAreFast() {
        let pages = (0..<10).map { page in
            (0..<10_000).map { i in bytes([("_id", .int32(Int32(page * 10_000 + i))), ("name", .string("n\(i)")),
                                         ("sub", .document(doc([("k", .int32(1))]))), ("late\(page)", .bool(true))]) }
        }
        let source = MongoDocumentSource()
        let elapsed = ContinuousClock().measure {
            for page in pages { source.append(page) }
            for row in stride(from: 0, to: 100_000, by: 1_000) { for column in source.columns.indices { _ = source.cell(row, column) } }
        }
        #expect(source.rowCount == 100_000 && source.columns.count == 13)
        #expect(elapsed < .seconds(10))
    }

    @Test func schemaCountsTypesValuesAndRanges() {
        let sample = [
            doc([("_id", .int32(1)), ("n", .int32(5)), ("when", .datetime(1_000)),
                 ("addr", .document(doc([("city", .string("Oslo")), ("zip", .null)]))),
                 ("tags", .array([.string("a"), .string("b")])),
                 ("items", .array([.document(doc([("price", .double(2.5))])), .document(doc([("price", .int64(7))]))]))]),
            doc([("_id", .int32(2)), ("n", .string("five")), ("when", .datetime(-5)), ("addr", .document(doc([("city", .string("Oslo"))]))),
                 ("tags", .array([.string("a")]))]),
            doc([("_id", .int32(3)), ("n", .null), ("addr", .string("none"))]),
            doc([("_id", .int32(4)), ("n", .decimal128(BSONDecimal128("-1.5")!))]),
        ]
        let schema = MongoSchema(sample: sample, topLimit: 2, distinctLimit: 3)
        #expect(schema.documents == 4)
        #expect(schema.fields.map(\.path) == ["_id", "n", "when", "addr", "addr.city", "addr.zip", "tags", "tags.[]", "items",
                                               "items.[]", "items.[].price"])
        let n = schema["n"]!
        #expect(n.present == 4 && n.missing == 0 && n.nulls == 1)
        #expect(n.share("int") == 0.25 && n.types.count == 4)
        #expect(n.minNumber == .decimal128(BSONDecimal128("-1.5")!) && n.maxNumber == .int32(5))
        let when = schema["when"]!
        #expect(when.missing == 2 && when.minDate == .datetime(-5) && when.maxDate == .datetime(1_000))
        let addr = schema["addr"]!
        #expect(addr.types.map(\.name) == ["object", "string"] && addr.top.map(\.value) == ["\"none\""])
        // Missing counts only where addr was a document.
        #expect(schema["addr.city"]!.present == 2 && schema["addr.city"]!.missing == 0)
        #expect(schema["addr.city"]!.top.first! == ("\"Oslo\"", 2) && schema["addr.city"]!.distinct == 1)
        #expect(schema["addr.zip"]!.missing == 1 && schema["addr.zip"]!.nulls == 1)
        let tags = schema["tags.[]"]!
        #expect(tags.present == 3 && tags.top.map(\.value) == ["\"a\"", "\"b\""] && tags.missing == 0)
        #expect(schema["tags"]!.missing == 2 && schema["tags"]!.types.map(\.name) == ["array"])
        let price = schema["items.[].price"]!
        #expect(price.present == 2 && price.missing == 0 && price.types.map(\.name) == ["double", "long"])
        #expect(price.minNumber == .double(2.5) && price.maxNumber == .int64(7))
        // Four distinct ids, three counted exactly: a lower bound, so marked inexact.
        #expect(schema["_id"]!.distinct == 3 && !schema["_id"]!.distinctIsExact && schema["n"]!.distinct == 3)
    }
}
