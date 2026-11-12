// The query builder's model (docs/dev/mongo-plan.md, Phase 5 A; lane P5-core): conditions to a filter and back, every
// operator and value type, whole days, escaped patterns, `$and` for repeated keys, what parse-back refuses, and the
// projection, sort and ignore-case collation.
import Foundation
import Testing
@testable import AirSQLCore

private typealias B = MongoBuilder
private func shell(_ text: String) -> BSONDocument { try! BSONDocument(shellForm: text) }
private func filter(_ rules: B.Rule..., any: Bool = false) throws -> String {
    try B.Group(any: any, rules.map(B.Condition.rule)).filter().shellForm()
}
private func day(_ text: String) -> BSONValue { .datetime(ShellDate.parse(text)!) }

struct MongoBuilderTests {
    static let id = "65a1b2c3d4e5f60718293a4b"

    // MARK: Writing

    @Test func everyOperatorWritesItsDocument() throws {
        let cases: [(B.Rule, String)] = [
            (B.Rule("name", .is, ["Ada"]), #"{ name: "Ada" }"#),
            (B.Rule("name", .isNot, ["Ada"]), #"{ name: { $ne: "Ada" } }"#),
            (B.Rule("name", .contains, ["a.b"]), #"{ name: /a\.b/ }"#),
            (B.Rule("name", .contains, ["ada"], ignoreCase: true), #"{ name: /ada/i }"#),
            (B.Rule("name", .notContains, ["x"]), #"{ name: { $not: /x/ } }"#),
            (B.Rule("name", .startsWith, ["A+"]), #"{ name: /^A\+/ }"#),
            (B.Rule("name", .endsWith, ["$"]), #"{ name: /\$$/ }"#),
            (B.Rule("name", .matches, ["^a.*z$"], ignoreCase: true), #"{ name: /^a.*z$/i }"#),
            (B.Rule("age", .greater, ["30"], type: .number), #"{ age: { $gt: NumberLong(30) } }"#),
            (B.Rule("age", .atLeast, ["2.5"], type: .number), #"{ age: { $gte: 2.5 } }"#),
            (B.Rule("age", .less, ["30"], type: .number), #"{ age: { $lt: NumberLong(30) } }"#),
            (B.Rule("age", .atMost, ["30"], type: .number), #"{ age: { $lte: NumberLong(30) } }"#),
            (B.Rule("age", .between, ["1", "2"], type: .number), #"{ age: { $gte: NumberLong(1), $lte: NumberLong(2) } }"#),
            (B.Rule("s", .oneOf, ["a", "b"]), #"{ s: { $in: [ "a", "b" ] } }"#),
            (B.Rule("s", .noneOf, ["a"]), #"{ s: { $nin: [ "a" ] } }"#),
            (B.Rule("s", .hasValue), #"{ s: { $ne: null } }"#),
            (B.Rule("s", .hasNoValue), #"{ s: null }"#),
            (B.Rule("_id", .is, [Self.id], type: .objectId), #"{ _id: ObjectId("\#(Self.id)") }"#),
            (B.Rule("ok", .is, ["TRUE"], type: .bool), #"{ ok: true }"#),
            (B.Rule("p", .is, [#"NumberDecimal("1.50")"#], type: .shell), #"{ p: NumberDecimal("1.50") }"#),
            (B.Rule("p", .is, [#"NumberDecimal("1.5")"#], type: .number), #"{ p: NumberDecimal("1.5") }"#),
            (B.Rule("u", .is, [#"UUID("0123456789abcdef0123456789abcdef")"#], type: .shell),
             #"{ u: UUID("01234567-89ab-cdef-0123-456789abcdef") }"#),
        ]
        for (rule, text) in cases { #expect(try filter(rule) == text, "\(rule.op)") }
        #expect(B.Operator.allCases.count == 16)
        #expect(B.Operator.contains.label == "contains — LIKE '%x%'" && B.Operator.oneOf.label == "is one of — IN (x, y)"
                && B.Operator.hasNoValue.label == "has no value — IS NULL")
    }

    @Test func operatorsFitTheirTypesAndArraysTheirElements() {
        #expect(B.Operator.fitting(.text) == B.Operator.allCases)
        #expect(B.Operator.fitting(.bool) == [.is, .isNot, .hasValue, .hasNoValue])
        #expect(!B.Operator.fitting(.number).contains(.contains) && B.Operator.fitting(.date).contains(.between))
        let schema = MongoSchema(sample: [shell(#"{ tags: ["a", "b"], items: [{ qty: 2 }], n: 1, d: ISODate("2026-01-01T00:00:00Z"), o: null }"#),
                                          shell(#"{ n: null, o: ObjectId("\#(Self.id)") }"#)])
        #expect(B.valueType(of: "tags", in: schema) == .text)
        #expect(B.valueType(of: "items.qty", in: schema) == .number)
        #expect(B.valueType(of: "n", in: schema) == .number && B.valueType(of: "d", in: schema) == .date)
        #expect(B.valueType(of: "o", in: schema) == .objectId && B.valueType(of: "missing", in: schema) == .text)
        #expect(B.valueType(of: "items", in: schema) == .shell)
    }

    @Test func valuesAreTypedOrSayWhatIsWrong() throws {
        #expect(try B.ValueType.number.value(" 42 ") == .int64(42))
        #expect(try B.ValueType.number.value("-2.5e3") == .double(-2500))
        #expect(try B.ValueType.number.value("9223372036854775807") == .int64(.max))
        #expect(try B.ValueType.text.value(" spaced ") == .string(" spaced "))
        #expect(try B.ValueType.date.value("2026-11-12 10:30") == .datetime(ShellDate.parse("2026-11-12T10:30:00Z")!))
        #expect(try B.ValueType.date.value("2026-11-12T12:30+02:00") == .datetime(ShellDate.parse("2026-11-12T10:30:00Z")!))
        #expect(try B.ValueType.date.value(#"ISODate("2026-11-12T10:30:00Z")"#) == day("2026-11-12T10:30:00Z"))
        #expect(try B.ValueType.objectId.value(#"ObjectId("\#(Self.id)")"#) == B.ValueType.objectId.value(Self.id))
        #expect(try B.ValueType.bool.value("false") == .bool(false))
        let bad: [(B.ValueType, String, String)] = [
            (.number, "abc", "‘abc’ isn't a number"), (.number, "nan", "‘nan’ isn't a number"), (.number, "", "Type a value"),
            (.date, "2026-13-01", "‘2026-13-01’ isn't a date: type 2026-11-12, 2026-11-12 10:30 or 2026-11-12T10:30:00Z (UTC)"),
            (.objectId, "123", "‘123’ isn't an ObjectId: type its 24 hex digits"), (.bool, "yes", "‘yes’ isn't true or false"),
            (.text, "  ", "Type a value"),
        ]
        for (type, text, message) in bad {
            #expect { try type.value(text) } throws: { ($0 as? BSONError)?.message == message }
        }
        #expect { try B.ValueType.shell.value("Foo(1)") } throws: { ($0 as? BSONError)?.message.hasPrefix("‘Foo(1)’ isn't a value in shell form") == true }
        // A rule's error names its field.
        #expect { try B.Rule("age", .is, ["x"], type: .number).clause() } throws: { ($0 as? BSONError)?.message == "age: ‘x’ isn't a number" }
        #expect { try B.Rule("age", .between, ["1"], type: .number).clause() } throws: { ($0 as? BSONError)?.message == "Type a value for age" }
        #expect { try B.Rule("", .is, ["1"]).clause() } throws: { ($0 as? BSONError)?.message == "Choose a field" }
        #expect { try B.Rule("$where", .is, ["1"]).clause() } throws: { $0 is BSONError }
        #expect { try B.Rule("a", .contains, [""]).clause() } throws: { $0 is BSONError }
        #expect { try B.Rule("a", .is, ["{ b: 1 }"], type: .shell).clause() } throws: { ($0 as? BSONError)?.message.contains("sub-document") == true }
        #expect { try B.Rule("a", .is, ["/x/"], type: .shell).clause() } throws: { ($0 as? BSONError)?.message.contains("matches pattern") == true }
    }

    @Test func aDayIsARangeAndBetweenDaysIncludesTheLast() throws {
        let d12 = day("2026-11-12"), d13 = day("2026-11-13"), d30 = day("2026-11-30"), d01 = day("2026-12-01")
        func doc(_ rule: B.Rule) throws -> BSONValue { try rule.clause()["d"]! }
        func ops(_ fields: (String, BSONValue)...) -> BSONValue { .document(BSONDocument(fields.map { ($0.0, $0.1) })) }
        #expect(try doc(B.Rule("d", .is, ["2026-11-12"], type: .date)) == ops(("$gte", d12), ("$lt", d13)))
        #expect(try doc(B.Rule("d", .isNot, ["2026-11-12"], type: .date)) == ops(("$not", ops(("$gte", d12), ("$lt", d13)))))
        #expect(try doc(B.Rule("d", .greater, ["2026-11-12"], type: .date)) == ops(("$gte", d13)))
        #expect(try doc(B.Rule("d", .atLeast, ["2026-11-12"], type: .date)) == ops(("$gte", d12)))
        #expect(try doc(B.Rule("d", .less, ["2026-11-12"], type: .date)) == ops(("$lt", d12)))
        #expect(try doc(B.Rule("d", .atMost, ["2026-11-12"], type: .date)) == ops(("$lt", d13)))
        #expect(try doc(B.Rule("d", .between, ["2026-11-01", "2026-11-30"], type: .date)) == ops(("$gte", day("2026-11-01")), ("$lt", d01)))
        #expect(try doc(B.Rule("d", .between, ["2026-11-01 08:00", "2026-11-30"], type: .date))
                == ops(("$gte", day("2026-11-01T08:00:00Z")), ("$lt", d01)))
        // With a time it is an instant.
        #expect(try doc(B.Rule("d", .is, ["2026-11-12 00:00"], type: .date)) == d12)
        #expect(try doc(B.Rule("d", .atMost, ["2026-11-30 10:00"], type: .date)) == ops(("$lte", day("2026-11-30T10:00:00Z"))))
        // Read back.
        let back = B.Group(filter: shell(#"{ d: { $gte: ISODate("2026-11-01T00:00:00Z"), $lt: ISODate("2026-12-01T00:00:00Z") } }"#))
        #expect(back == B.Group([.rule(B.Rule("d", .between, ["2026-11-01", "2026-11-30"], type: .date))]))
        #expect(B.Group(filter: BSONDocument([("d", ops(("$gte", d12), ("$lt", d13)))]))
                == B.Group([.rule(B.Rule("d", .is, ["2026-11-12"], type: .date))]))
        #expect(B.Group(filter: BSONDocument([("d", d30)])) == B.Group([.rule(B.Rule("d", .is, ["2026-11-30 00:00"], type: .date))]))
        #expect(B.Group(filter: BSONDocument([("d", day("2026-11-30T10:00:05.250Z"))]))
                == B.Group([.rule(B.Rule("d", .is, ["2026-11-30T10:00:05.250Z"], type: .date))]))
    }

    @Test func presetsAreWholeDaysOfTheCalendar() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: TimeInterval(ShellDate.parse("2026-11-12T23:30:00Z")!) / 1000)
        #expect(B.DatePreset.today.values(now: now, calendar: utc) == ["2026-11-12", "2026-11-12"])
        #expect(B.DatePreset.last7Days.values(now: now, calendar: utc) == ["2026-11-06", "2026-11-12"])
        #expect(B.DatePreset.thisMonth.values(now: now, calendar: utc) == ["2026-11-01", "2026-11-30"])
        var tokyo = utc
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        #expect(B.DatePreset.today.values(now: now, calendar: tokyo) == ["2026-11-13", "2026-11-13"])
        #expect(B.DatePreset.thisMonth.values(now: now, calendar: tokyo) == ["2026-11-01", "2026-11-30"])
    }

    @Test func patternsEscapeEveryMetacharacter() throws {
        let all = #"\^$.|?*+()[]{}"#
        #expect(B.escapedPattern(all) == #"\\\^\$\.\|\?\*\+\(\)\[\]\{\}"#)
        #expect(B.escapedPattern("a-b c/d") == "a-b c/d")
        for text in [all, "a.b", "x/y", "ünï", "end\\"] {
            let regex = try NSRegularExpression(pattern: B.escapedPattern(text))
            let whole = "<" + text + ">"
            #expect(regex.firstMatch(in: whole, range: NSRange(whole.startIndex..., in: whole))?.range == NSRange(location: 1, length: (text as NSString).length))
            for op in [B.Operator.contains, .startsWith, .endsWith, .notContains] {
                let rule = B.Rule("a", op, [text], ignoreCase: true)
                let read = B.Group(filter: try BSONDocument(shellForm: try rule.clause().shellForm()))
                #expect(read == B.Group([.rule(rule)]), "\(op) \(text)")
            }
        }
        // A real pattern reads back as matches pattern; options other than i stay text.
        #expect(B.Group(filter: shell(#"{ a: /^ab\d$/ }"#)) == B.Group([.rule(B.Rule("a", .matches, [#"^ab\d$"#]))]))
        #expect(B.Group(filter: shell(#"{ a: /x/m }"#)) == nil)
        #expect(B.Group(filter: shell(#"{ a: { $not: /^x/ } }"#)) == nil)
    }

    @Test func repeatedKeysAndSeveralAnyGroupsUseAnd() throws {
        #expect(try filter(B.Rule("a", .atLeast, ["1"], type: .number), B.Rule("b", .is, ["x"]))
                == #"{ a: { $gte: NumberLong(1) }, b: "x" }"#)
        #expect(try filter(B.Rule("a", .atLeast, ["1"], type: .number), B.Rule("a", .less, ["5"], type: .number))
                == "{ $and: [ { a: { $gte: NumberLong(1) } }, { a: { $lt: NumberLong(5) } } ] }")
        let anyAB = B.Condition.group(B.Group(any: true, [.rule(B.Rule("a", .is, ["1"])), .rule(B.Rule("b", .is, ["2"]))]))
        let anyC = B.Condition.group(B.Group(any: true, [.rule(B.Rule("c", .is, ["3"]))]))
        #expect(try B.Group([.rule(B.Rule("x", .hasValue)), anyAB]).filter().shellForm()
                == #"{ x: { $ne: null }, $or: [ { a: "1" }, { b: "2" } ] }"#)
        #expect(try B.Group([anyAB, anyC]).filter().shellForm()
                == #"{ $and: [ { $or: [ { a: "1" }, { b: "2" } ] }, { $or: [ { c: "3" } ] } ] }"#)
        // Empty groups are dropped; an any-group of all-groups.
        #expect(try B.Group([.group(B.Group(any: true)), .rule(B.Rule("a", .is, ["1"]))]).filter().shellForm() == #"{ a: "1" }"#)
        #expect(try B.Group().filter().fields.isEmpty && B.Group(any: true, [.group(B.Group())]).filter().fields.isEmpty)
        let allAA = B.Condition.group(B.Group([.rule(B.Rule("a", .is, ["1"])), .rule(B.Rule("a", .isNot, ["2"]))]))
        #expect(try B.Group(any: true, [allAA, .rule(B.Rule("b", .is, ["3"]))]).filter().shellForm()
                == #"{ $or: [ { $and: [ { a: "1" }, { a: { $ne: "2" } } ] }, { b: "3" } ] }"#)
    }

    // MARK: Reading back

    @Test func plainShapesReadBack() {
        #expect(B.Group(filter: shell("{}")) == B.Group())
        #expect(B.Group(filter: shell("{ a: 1 }")) == B.Group([.rule(B.Rule("a", .is, ["1"], type: .number))]))
        #expect(B.Group(filter: shell(#"{ a: { $exists: true }, b: { $exists: false }, c: { $eq: null }, s: "" }"#))
                == B.Group([.rule(B.Rule("a", .hasValue)), .rule(B.Rule("b", .hasNoValue)), .rule(B.Rule("c", .hasNoValue)),
                            .rule(B.Rule("s", .is, [#""""#], type: .shell))]))
        #expect(B.Group(filter: shell("{ age: { $gte: 18, $lt: 65 } }"))
                == B.Group([.rule(B.Rule("age", .atLeast, ["18"], type: .number)), .rule(B.Rule("age", .less, ["65"], type: .number))]))
        #expect(B.Group(filter: shell("{ $or: [ { age: { $gte: 18, $lt: 65 } }, { vip: true } ] }"))
                == B.Group(any: true, [.group(B.Group([.rule(B.Rule("age", .atLeast, ["18"], type: .number)),
                                                       .rule(B.Rule("age", .less, ["65"], type: .number))])),
                                       .rule(B.Rule("vip", .is, ["true"], type: .bool))]))
        #expect(B.Group(filter: shell(#"{ a: { $in: [ 1, "x", NumberDecimal("2") ] } }"#))
                == B.Group([.rule(B.Rule("a", .oneOf, ["1", #""x""#, #"NumberDecimal("2")"#], type: .shell))]))
    }

    @Test func parseBackRefusesWhatItCannotShow() {
        let refused = [
            #"{ a: 1, a: 2 }"#, "{ a: { $gt: 1, $gt: 2 } }", "{ a: { b: 1 } }", "{ a: [ 1, 2 ] }", "{ a: { $eq: /x/ } }",
            "{ a: { $eq: { b: 1 } } }", "{ a: { $in: [ [ 1 ] ] } }", "{ a: { $in: [] } }", "{ a: { $elemMatch: { b: 1 } } }",
            "{ $nor: [ { a: 1 } ] }", "{ a: { $size: 2 } }", "{ a: { $regex: \"x\" } }", "{ $expr: { $eq: [ 1, 1 ] } }",
            "{ a: { $not: { $gt: 1 } } }", "{ a: { $exists: 1 } }", "{ $or: [] }", "{ $or: [ {} ] }", "{ $or: [ 1 ] }",
            // Deeper than one group.
            "{ $or: [ { $or: [ { a: 1 } ] } ] }", "{ $or: [ { a: 1, $or: [ { b: 1 } ] } ] }",
            "{ $and: [ { $or: [ { a: 1, b: 1 } ] } ] }", "{ x: 1, $or: [ { $or: [ { a: 1 } ] } ] }",
        ]
        for text in refused { #expect(B.Group(filter: shell(text)) == nil, "\(text)") }
    }

    /// Every operator with every type it fits: build → shell text → parse → build gives the same document.
    @Test func everyOperatorAndTypeRoundTrips() throws {
        let values: [B.ValueType: [[String]]] = [
            .text: [["Ada (x)*", "Zed"], ["  spaced", "a,b"]],
            .number: [["42", "-7"], ["2.5", "1e-05"]],
            .date: [["2026-11-12", "2026-11-30"], ["2026-11-12 10:30", "2026-11-30T10:00:05.250Z"], ["2026-11-12 00:00", "2026-11-30"]],
            .objectId: [[Self.id, "65a1b2c3d4e5f60718293a4c"]],
            .bool: [["true", "false"]],
            .shell: [[#"NumberDecimal("1.5")"#, #"UUID("0123456789abcdef0123456789abcdef")"#], [#"Timestamp({ t: 1, i: 2 })"#, "MinKey()"]],
        ]
        var count = 0
        for (type, sets) in values {
            for vs in sets {
                for op in B.Operator.fitting(type) {
                    for ignoreCase in op.isPattern ? [false, true] : [false] {
                        let given: [String]
                        switch op.arity {
                        case .none: given = []
                        case .one: given = [vs[0]]
                        case .two, .list: given = vs
                        }
                        let rule = B.Rule("f.g", op, given, type: type, ignoreCase: ignoreCase)
                        let groups = [B.Group([.rule(rule)]), B.Group(any: true, [.rule(rule), .rule(B.Rule("f.g", .hasValue))]),
                                      B.Group([.rule(rule), .group(B.Group(any: true, [.rule(rule), .rule(B.Rule("z", .is, ["1"]))]))])]
                        for group in groups {
                            let built = try group.filter()
                            let read = try #require(B.Group(filter: try BSONDocument(shellForm: built.shellForm())), "\(type) \(op) \(built.shellForm())")
                            #expect(try read.filter() == built, "\(type) \(op) \(built.shellForm())")
                            count += 1
                        }
                    }
                }
            }
        }
        #expect(count > 300)
    }

    // MARK: Lists, projection, sort, collation, arrays

    @Test func listsSplitAtCommasOutsideQuotes() {
        #expect(B.listItems(#" a, "b, c" ,, ObjectId("x"), "say \"hi\"" "#) == ["a", "b, c", #"ObjectId("x")"#, #"say "hi""#])
        for items in [["a", "b, c", #""q""#, " pad ", #"Timestamp({ t: 1, i: 2 })"#], ["x"]] {
            #expect(B.listItems(B.listText(items)) == items)
        }
    }

    @Test func projectionSortAndCollationToAndFromDocuments() {
        #expect(B.Projection().document == nil)
        #expect(B.Projection(paths: ["a", "b.c"]).document?.shellForm() == #"{ a: 1, "b.c": 1 }"#)
        #expect(B.Projection(paths: ["a"], includeId: false).document?.shellForm() == "{ a: 1, _id: 0 }")
        #expect(B.Projection(includeId: false).document?.shellForm() == "{ _id: 0 }")
        #expect(B.Projection(document: shell("{ a: true, _id: 0, b: 1.0 }")) == B.Projection(paths: ["a", "b"], includeId: false))
        #expect(B.Projection(document: nil) == B.Projection())
        for text in ["{ a: 0 }", "{ _id: 1 }", "{ a: \"$b\" }", "{ a: 1, a: 1 }", "{ a: { $slice: 2 } }", "{}"] {
            #expect(B.Projection(document: shell(text)) == nil, "\(text)")
        }
        #expect(B.sortDocument([B.SortKey("a"), B.SortKey("b", ascending: false)])?.shellForm() == "{ a: 1, b: -1 }")
        #expect(B.sortDocument([]) == nil && B.sortKeys(nil) == [])
        #expect(B.sortKeys(shell("{ a: -1, b: NumberLong(1) }")) == [B.SortKey("a", ascending: false), B.SortKey("b")])
        for text in ["{ a: 2 }", "{ s: { $meta: \"textScore\" } }", "{ a: 1, a: -1 }"] { #expect(B.sortKeys(shell(text)) == nil) }
        #expect(B.ignoreCaseCollation.shellForm() == #"{ locale: "en", strength: 2 }"#)
        #expect(B.ignoresCase(nil) == false && B.ignoresCase(B.ignoreCaseCollation) == true)
        #expect(B.ignoresCase(shell(#"{ locale: "fr", strength: 2 }"#)) == nil && B.ignoresCase(shell(#"{ locale: "en" }"#)) == nil)
    }

    @Test func rulesUnderOneArrayAreNoted() {
        let arrays = ["items.[]", "items.[].sku", "items.[].tags.[]", "tags.[]", "name"]
        #expect(B.sharedArrays(paths: ["items.sku", "items.qty", "name", "tags", "items.tags"], arrayPaths: arrays)
                == ["items", "items", nil, nil, "items"])
        #expect(B.sharedArrays(paths: ["items.sku", "items.sku"], arrayPaths: arrays) == ["items", "items"])
    }
}
