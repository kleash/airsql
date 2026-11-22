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
            (B.Rule("age", .greater, ["30"], type: .number), #"{ age: { $gt: 30 } }"#),
            (B.Rule("age", .atLeast, ["2.5"], type: .number), #"{ age: { $gte: 2.5 } }"#),
            (B.Rule("age", .less, ["30"], type: .number), #"{ age: { $lt: 30 } }"#),
            (B.Rule("age", .atMost, ["30"], type: .number), #"{ age: { $lte: 30 } }"#),
            (B.Rule("age", .between, ["1", "2"], type: .number), #"{ age: { $gte: 1, $lte: 2 } }"#),
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
        #expect(try B.ValueType.number.value(" 42 ") == .int32(42))
        #expect(try B.ValueType.number.value("2147483648") == .int64(2_147_483_648))
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
                == #"{ a: { $gte: 1 }, b: "x" }"#)
        // A field's operators are merged while none repeats; then it is $and, in the rules' order.
        #expect(try filter(B.Rule("a", .atLeast, ["1"], type: .number), B.Rule("b", .is, ["x"]), B.Rule("a", .less, ["5"], type: .number))
                == #"{ a: { $gte: 1, $lt: 5 }, b: "x" }"#)
        #expect(try filter(B.Rule("a", .atLeast, ["1"], type: .number), B.Rule("b", .is, ["x"]), B.Rule("a", .atLeast, ["5"], type: .number))
                == #"{ $and: [ { a: { $gte: 1 } }, { b: "x" }, { a: { $gte: 5 } } ] }"#)
        #expect(try filter(B.Rule("a", .is, ["1"]), B.Rule("a", .isNot, ["2"])) == #"{ $and: [ { a: "1" }, { a: { $ne: "2" } } ] }"#)
        #expect(try filter(B.Rule("a", .contains, ["x"]), B.Rule("a", .notContains, ["y"])) == "{ $and: [ { a: /x/ }, { a: { $not: /y/ } } ] }")
        #expect(try filter(B.Rule("a", .hasValue), B.Rule("a", .isNot, ["2"])) == #"{ $and: [ { a: { $ne: null } }, { a: { $ne: "2" } } ] }"#)
        #expect(try filter(B.Rule("a", .notContains, ["x"]), B.Rule("a", .hasValue)) == "{ a: { $not: /x/, $ne: null } }")
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
            "{ a: { $eq: { b: 1 } } }", "{ a: { $in: [ [ 1 ] ] } }", "{ a: { $in: [] } }",
            "{ $nor: [ { a: 1 } ] }", "{ a: { $size: 2 } }", "{ a: { $regex: \"x\" } }", "{ $expr: { $eq: [ 1, 1 ] } }",
            "{ a: { $not: { $gt: 1 } } }", "{ a: { $exists: 1 } }", "{ $or: [] }", "{ $or: [ {} ] }", "{ $or: [ 1 ] }",
            // Something unreadable deep inside groups.
            "{ $or: [ { a: 1, $or: [ { b: 1 }, { $or: [ { c: { $size: 1 } } ] } ] } ] }", "{ $or: [ { $and: [] } ] }",
        ]
        for text in refused { #expect(B.Group(filter: shell(text)) == nil, "\(text)") }
    }

    @Test func groupsInsideGroupsReadBackToAnyDepth() throws {
        let a = B.Rule("a", .is, ["1"], type: .number), b = B.Rule("b", .is, ["1"], type: .number), x = B.Rule("x", .is, ["1"], type: .number)
        let read: [(String, B.Group)] = [
            ("{ $or: [ { $or: [ { a: 1 } ] } ] }", B.Group(any: true, [.group(B.Group([.group(B.Group(any: true, [.rule(a)]))]))])),
            ("{ $or: [ { a: 1, $or: [ { b: 1 } ] } ] }", B.Group(any: true, [.group(B.Group([.rule(a), .group(B.Group(any: true, [.rule(b)]))]))])),
            ("{ x: 1, $or: [ { $or: [ { a: 1 } ] } ] }",
             B.Group([.rule(x), .group(B.Group(any: true, [.group(B.Group([.group(B.Group(any: true, [.rule(a)]))]))]))])),
            ("{ $and: [ { $or: [ { a: 1, b: 1 } ] } ] }", B.Group([.group(B.Group(any: true, [.group(B.Group([.rule(a), .rule(b)]))]))])),
        ]
        for (text, group) in read {
            #expect(B.Group(filter: shell(text)) == group, "\(text)")
            #expect(try B.Group(filter: try group.filter())?.filter() == group.filter(), "\(text)")
        }
        #expect(try read[0].1.filter() == shell(read[0].0) && read[2].1.filter() == shell(read[2].0))

        // Four levels with an item at the bottom: the document, then the same groups from it.
        let item = B.Item("items", B.Group(any: true, [.rule(B.Rule("sku", .is, ["A1"])),
                                                       .group(B.Group([.rule(B.Rule("qty", .atLeast, ["1"], type: .number)),
                                                                       .rule(B.Rule("qty", .less, ["5"], type: .number))]))]))
        let deep = B.Group([.rule(x), .group(B.Group(any: true, [.rule(a), .group(B.Group([.rule(b), .group(B.Group(any: true, [
            .rule(B.Rule("c", .is, ["z"])), .group(B.Group([.rule(B.Rule("d", .hasValue)), .item(item)]))]))]))]))])
        let built = try deep.filter()
        #expect(built.shellForm() == #"{ x: 1, $or: [ { a: 1 }, { b: 1, $or: [ { c: "z" }, { d: { $ne: null }, "#
                + #"items: { $elemMatch: { $or: [ { sku: "A1" }, { qty: { $gte: 1, $lt: 5 } } ] } } } ] } ] }"#)
        #expect(B.Group(filter: try BSONDocument(shellForm: built.shellForm())) == deep)
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
                                      B.Group([.rule(rule), .group(B.Group(any: true, [.rule(rule), .rule(B.Rule("z", .is, ["1"]))]))]),
                                      B.Group(any: true, [.rule(B.Rule("z", .is, ["1"])), .group(B.Group([.rule(rule), .group(B.Group(any: true, [
                                          .rule(rule), .group(B.Group([.rule(rule), .rule(B.Rule("y", .hasValue))]))]))]))])]
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
        #expect(count > 400)
    }

    /// Two rules on one field, every pair of operators of a type: merged or `$and`, the round trip is exact.
    @Test func sameFieldPairsRoundTrip() throws {
        let values: [B.ValueType: [String]] = [.text: ["Ada", "Zed"], .number: ["5", "7.5"],
                                               .date: ["2026-11-12", "2026-11-30 10:00"], .objectId: [Self.id, "65a1b2c3d4e5f60718293a4c"]]
        var count = 0
        for (type, vs) in values {
            func rule(_ op: B.Operator) -> B.Rule {
                switch op.arity {
                case .none: return B.Rule("a", op, type: type)
                case .one: return B.Rule("a", op, [vs[0]], type: type)
                case .two, .list: return B.Rule("a", op, vs, type: type)
                }
            }
            for first in B.Operator.fitting(type) {
                for second in B.Operator.fitting(type) {
                    let built = try B.Group([.rule(rule(first)), .rule(B.Rule("b", .is, ["1"])), .rule(rule(second))]).filter()
                    let read = try #require(B.Group(filter: try BSONDocument(shellForm: built.shellForm())), "\(built.shellForm())")
                    #expect(try read.filter() == built, "\(built.shellForm())")
                    count += 1
                }
            }
        }
        #expect(count > 500)
    }

    // MARK: Items of an array ($elemMatch)

    @Test func anItemWritesElemMatchAndReadsBack() throws {
        let cases: [(B.Item, String)] = [
            (B.Item("items", B.Group([.rule(B.Rule("sku", .is, ["A1"])), .rule(B.Rule("qty", .greater, ["2"], type: .number))])),
             #"{ items: { $elemMatch: { sku: "A1", qty: { $gt: 2 } } } }"#),
            (B.Item("items", B.Group(any: true, [.rule(B.Rule("sku", .is, ["A1"])), .rule(B.Rule("sku", .startsWith, ["B"]))])),
             #"{ items: { $elemMatch: { $or: [ { sku: "A1" }, { sku: /^B/ } ] } } }"#),
            // The item's own value, for an array of plain values: its operators only.
            (B.Item("scores", B.Group([.rule(B.Rule("", .atLeast, ["80"], type: .number)), .rule(B.Rule("", .less, ["85"], type: .number))])),
             "{ scores: { $elemMatch: { $gte: 80, $lt: 85 } } }"),
            (B.Item("tags", B.Group([.rule(B.Rule("", .startsWith, ["a"], ignoreCase: true))])), "{ tags: { $elemMatch: { $regex: /^a/i } } }"),
            (B.Item("tags", B.Group([.rule(B.Rule("", .is, ["x"]))])), #"{ tags: { $elemMatch: { $eq: "x" } } }"#),
            (B.Item("tags", B.Group([.rule(B.Rule("", .hasNoValue))])), "{ tags: { $elemMatch: { $eq: null } } }"),
            (B.Item("d", B.Group([.rule(B.Rule("", .is, ["2026-11-12"], type: .date))])),
             #"{ d: { $elemMatch: { $gte: ISODate("2026-11-12T00:00:00.000Z"), $lt: ISODate("2026-11-13T00:00:00.000Z") } } }"#),
            // An item in an item: an array of arrays of documents.
            (B.Item("orders", B.Group([.rule(B.Rule("paid", .is, ["true"], type: .bool)),
                                       .item(B.Item("lines", B.Group([.rule(B.Rule("sku", .is, ["A1"]))])))])),
             #"{ orders: { $elemMatch: { paid: true, lines: { $elemMatch: { sku: "A1" } } } } }"#),
        ]
        for (item, text) in cases {
            #expect(try item.clause().shellForm() == text)
            #expect(B.Group(filter: shell(text)) == B.Group([.item(item)]), "\(text)")
        }
        // Beside a rule on the same array it stays its own part, so it reads back as the item.
        let both = B.Group([.rule(B.Rule("items", .hasValue)), .item(cases[0].0)])
        #expect(try both.filter().shellForm() == #"{ $and: [ { items: { $ne: null } }, { items: { $elemMatch: { sku: "A1", qty: { $gt: 2 } } } } ] }"#)
        #expect(B.Group(filter: try both.filter()) == both)
        let anyOf = B.Group(any: true, [.item(cases[4].0), .rule(B.Rule("tags", .hasNoValue))])
        #expect(B.Group(filter: try anyOf.filter()) == anyOf)
    }

    /// Every operator with every type it fits, on the item's own value and on a field of it: the round trip is exact.
    @Test func everyOperatorRoundTripsInAnItem() throws {
        let values: [B.ValueType: [String]] = [.text: ["Ada (x)*", "Zed"], .number: ["42", "2.5"], .date: ["2026-11-12", "2026-11-30 10:00"],
                                               .objectId: [Self.id, "65a1b2c3d4e5f60718293a4c"], .bool: ["true", "false"],
                                               .shell: [#"NumberDecimal("1.5")"#, "MinKey()"]]
        var count = 0
        for (type, vs) in values {
            for op in B.Operator.fitting(type) {
                for ignoreCase in op.isPattern ? [false, true] : [false] {
                    let given = op.arity == .none ? [] : op.arity == .one ? [vs[0]] : vs
                    for path in ["", "f.g"] {
                        let item = B.Group([.item(B.Item("arr", B.Group([.rule(B.Rule(path, op, given, type: type, ignoreCase: ignoreCase))])))])
                        let built = try item.filter()
                        let read = try #require(B.Group(filter: try BSONDocument(shellForm: built.shellForm())), "\(built.shellForm())")
                        #expect(try read.filter() == built, "\(built.shellForm())")
                        count += 1
                    }
                }
            }
        }
        #expect(count > 100)
    }

    @Test func anItemSaysWhatIsWrongAndOddShapesStayText() {
        let bad: [(B.Item, String)] = [
            (B.Item("", B.Group([.rule(B.Rule("sku", .is, ["a"]))])), "Choose the array field for the item"),
            (B.Item("$x", B.Group([.rule(B.Rule("sku", .is, ["a"]))])), "‘$x’: a field's name can't start with $"),
            (B.Item("tags"), "Add a condition on the items of tags"),
            (B.Item("tags", B.Group([.group(B.Group(any: true))])), "Add a condition on the items of tags"),
            (B.Item("tags", B.Group([.rule(B.Rule("", .is))])), "Type a value for the item"),
            (B.Item("tags", B.Group([.rule(B.Rule("", .is, ["x"])), .rule(B.Rule("sku", .is, ["a"]))])),
             "tags: conditions on the item itself can't sit with conditions on its fields, in groups or under any"),
            (B.Item("tags", B.Group(any: true, [.rule(B.Rule("", .is, ["x"])), .rule(B.Rule("", .is, ["y"]))])),
             "tags: conditions on the item itself can't sit with conditions on its fields, in groups or under any"),
            (B.Item("n", B.Group([.rule(B.Rule("", .hasValue)), .rule(B.Rule("", .isNot, ["2"]))])),
             "n: two conditions on the item both use $ne: put them in two items"),
        ]
        for (item, message) in bad {
            #expect { try item.clause() } throws: { ($0 as? BSONError)?.message == message }
            #expect { try B.Group([.item(item)]).filter() } throws: { ($0 as? BSONError)?.message == message }
        }
        let text = [
            "{ a: { $elemMatch: {} } }", "{ a: { $elemMatch: 1 } }", "{ a: { $elemMatch: { $gt: 1, b: 1 } } }",
            "{ a: { $elemMatch: { b: 1 }, $size: 2 } }", #"{ a: { $elemMatch: { $regex: "x" } } }"#, "{ a: { $elemMatch: { $size: 2 } } }",
            "{ a: { $elemMatch: { b: { c: 1 } } } }", "{ a: { $elemMatch: { $and: [ { $gt: 1 } ] } } }", "{ b: { $regex: /x/ } }",
        ]
        for filter in text { #expect(B.Group(filter: shell(filter)) == nil, "\(filter)") }
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
