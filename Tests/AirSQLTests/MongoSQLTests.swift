// Query with SQL (docs/dev/mongo-plan.md, Phase 5 C): one SELECT to an aggregation pipeline, or refused with the part
// and where it is; then the lab (AIRSQL_MONGO_LAB=1): questions about `shop` asked in SQL, answered as the oracle
// (testenv/mongo/seed/shop-oracle.js, shop-answers.json) answers them, on the standalone and the replica set.
import Foundation
import Testing
@testable import AirSQLCore

/// The pipeline in shell form, a stage a line.
private func pipe(_ sql: String, sample: ((String) -> MongoSample?)? = nil) throws -> String {
    try MongoSQL.translate(sql, sample: sample).pipeline.map { $0.shellForm() }.joined(separator: "\n")
}

private func refusal(_ sql: String) -> MongoSQL.Refusal? {
    do { _ = try MongoSQL.translate(sql); return nil } catch { return error as? MongoSQL.Refusal }
}

private func notes(_ sql: String, sample: ((String) -> MongoSample?)? = nil) throws -> [String] {
    try MongoSQL.translate(sql, sample: sample).notes
}

struct MongoSQLTests {
    @Test func selectListProjectsTheColumnsInOrder() throws {
        #expect(try pipe("SELECT * FROM orders") == "")
        #expect(try pipe("SELECT status, total AS amount, address.city FROM orders")
                == #"{ $project: { _id: 0, status: "$status", amount: "$total", city: "$address.city" } }"#)
        #expect(try pipe("SELECT _id, o.items.sku, `a.b` AS ab FROM orders o")
                == #"{ $project: { _id: "$_id", sku: "$items.sku", ab: "$a.b" } }"#, "a backquoted name with dots is that path")
        let translation = try MongoSQL.translate("select o.status from `orders` o")
        #expect(translation.collection == "orders" && translation.joined.isEmpty && translation.notes.isEmpty)
        #expect(try pipe("SELECT orders.status FROM orders") == #"{ $project: { _id: 0, status: "$status" } }"#)
    }

    @Test func everyComparisonOperator() throws {
        #expect(try pipe("SELECT * FROM t WHERE a = 'x'") == #"{ $match: { a: "x" } }"#)
        #expect(try pipe("SELECT * FROM t WHERE a <> 1 AND b != 2") == "{ $match: { a: { $ne: 1 }, b: { $ne: 2 } } }")
        #expect(try pipe("SELECT * FROM t WHERE a < 1 AND b <= 2 AND c > 3 AND d >= 4")
                == "{ $match: { a: { $lt: 1 }, b: { $lte: 2 }, c: { $gt: 3 }, d: { $gte: 4 } } }")
        #expect(try pipe("SELECT * FROM t WHERE 5 < a AND 6 >= b") == "{ $match: { a: { $gt: 5 }, b: { $lte: 6 } } }",
                "a literal first turns the operator round")
        #expect(try pipe("SELECT * FROM t WHERE a IN ('x', 'y') AND b NOT IN (1)")
                == #"{ $match: { a: { $in: [ "x", "y" ] }, b: { $nin: [ 1 ] } } }"#)
        #expect(try pipe("SELECT * FROM t WHERE a BETWEEN 1 AND 2 OR b NOT BETWEEN 3 AND 4")
                == "{ $match: { $or: [ { a: { $gte: 1, $lte: 2 } }, { b: { $not: { $gte: 3, $lte: 4 } } } ] } }")
        #expect(try pipe("SELECT * FROM t WHERE a IS NULL AND b IS NOT NULL") == "{ $match: { a: null, b: { $ne: null } } }")
        #expect(try pipe("SELECT * FROM t WHERE NOT (a = 1)") == "{ $match: { $nor: [ { a: 1 } ] } }")
    }

    @Test func andMergesUnlessAKeyRepeats() throws {
        #expect(try pipe("SELECT * FROM t WHERE a > 1 AND a < 5")
                == "{ $match: { $and: [ { a: { $gt: 1 } }, { a: { $lt: 5 } } ] } }")
        #expect(try pipe("SELECT * FROM t WHERE (a = 1 OR b = 2) AND (c = 3 OR d = 4)")
                == "{ $match: { $and: [ { $or: [ { a: 1 }, { b: 2 } ] }, { $or: [ { c: 3 }, { d: 4 } ] } ] } }")
    }

    @Test func likeIsAnAnchoredEscapedRegexIgnoringCase() throws {
        #expect(try pipe("SELECT * FROM t WHERE a LIKE 'Ab_c'") == #"{ $match: { a: /^Ab.c\z/is } }"#)
        #expect(try pipe("SELECT * FROM t WHERE a LIKE 'ab%'") == "{ $match: { a: /^ab/is } }")
        #expect(try pipe("SELECT * FROM t WHERE a LIKE '%ab'") == #"{ $match: { a: /ab\z/is } }"#)
        #expect(try pipe("SELECT * FROM t WHERE a LIKE '%a.b(c)%'") == #"{ $match: { a: /a\.b\(c\)/is } }"#)
        #expect(try pipe("SELECT * FROM t WHERE a LIKE 'a%b'") == #"{ $match: { a: /^a.*b\z/is } }"#)
        #expect(try pipe(#"SELECT * FROM t WHERE a LIKE '50\%' AND b NOT LIKE '%x\_y%'"#)
                == #"{ $match: { a: /^50%\z/is, b: { $not: /x_y/is } } }"#)
        let any = try MongoSQL.translate("SELECT * FROM t WHERE a LIKE '%' AND b LIKE '%%'").pipeline
        #expect(any == [BSONDocument([("$match", .document(BSONDocument([("a", .regex(pattern: "", options: "is")),
                                                                          ("b", .regex(pattern: "", options: "is"))])))])])
    }

    @Test func everyLiteral() throws {
        #expect(try pipe(#"SELECT * FROM t WHERE a = 'it''s' AND b = "q" AND c = 'x' 'y'"#)
                == #"{ $match: { a: "it's", b: "q", c: "xy" } }"#)
        #expect(try pipe("SELECT * FROM t WHERE a = 42 AND b = -7 AND c = 1.5 AND d = 2e3 AND e = -0.25")
                == "{ $match: { a: 42, b: -7, c: 1.5, d: 2000.0, e: -0.25 } }")
        #expect(try pipe("SELECT * FROM t WHERE a = TRUE AND b = false") == "{ $match: { a: true, b: false } }")
        #expect(try pipe("SELECT * FROM t WHERE a >= DATE '2024-02-29' AND b < TIMESTAMP '2024-03-01 10:11:12.5' AND c = TIMESTAMP '2024-03-01'")
                == #"{ $match: { a: { $gte: ISODate("2024-02-29T00:00:00.000Z") }, b: { $lt: ISODate("2024-03-01T10:11:12.500Z") }, c: ISODate("2024-03-01T00:00:00.000Z") } }"#)
        #expect(try pipe("SELECT * FROM t WHERE _id = ObjectId('0a00000000000000000002bc')")
                == #"{ $match: { _id: ObjectId("0a00000000000000000002bc") } }"#)
    }

    @Test func joinsAreLookupsWithTheirAliasAsAs() throws {
        let sql = """
        SELECT o._id, o.total, c.name, c.address.city AS city FROM orders o JOIN customers c ON o.customerId = c._id
        LEFT JOIN products AS p ON p.sku = o.sku WHERE o.status = 'paid' AND c.country = 'DE' AND o.total > 10
        """
        #expect(try pipe(sql) == """
        { $match: { status: "paid", total: { $gt: 10 } } }
        { $lookup: { from: "customers", localField: "customerId", foreignField: "_id", as: "c" } }
        { $unwind: { path: "$c" } }
        { $lookup: { from: "products", localField: "sku", foreignField: "sku", as: "p" } }
        { $unwind: { path: "$p", preserveNullAndEmptyArrays: true } }
        { $match: { "c.country": "DE" } }
        { $project: { _id: "$_id", total: "$total", name: "$c.name", city: "$c.address.city" } }
        """)
        let translation = try MongoSQL.translate(sql)
        #expect(translation.collection == "orders" && translation.joined == ["customers", "products"])
        #expect(translation.notes.contains(MongoSQL.joinNote))

        // Without aliases the collection's name is `as`; a later join may join on an earlier one's field.
        #expect(try pipe("SELECT * FROM orders JOIN customers ON customers._id = orders.customerId JOIN countries ON countries.code = customers.country")
                == """
                { $lookup: { from: "customers", localField: "customerId", foreignField: "_id", as: "customers" } }
                { $unwind: { path: "$customers" } }
                { $lookup: { from: "countries", localField: "customers.country", foreignField: "code", as: "countries" } }
                { $unwind: { path: "$countries" } }
                """)
        // An OR across collections goes after the lookups as a whole.
        #expect(try pipe("SELECT * FROM o JOIN c ON o.x = c.y WHERE o.a = 1 OR c.b = 2") == """
        { $lookup: { from: "c", localField: "x", foreignField: "y", as: "c" } }
        { $unwind: { path: "$c" } }
        { $match: { $or: [ { a: 1 }, { "c.b": 2 } ] } }
        """)
    }

    @Test func groupByWithAggregatesAndHaving() throws {
        #expect(try pipe("SELECT status, COUNT(*) AS n, SUM(total) AS sum, AVG(total) avg, MIN(total) AS lo, MAX(o.total) AS hi FROM orders o GROUP BY status")
                == """
                { $group: { _id: "$status", n: { $sum: 1 }, sum: { $sum: "$total" }, avg: { $avg: "$total" }, lo: { $min: "$total" }, hi: { $max: "$total" } } }
                { $project: { _id: 0, status: "$_id", n: "$n", sum: "$sum", avg: "$avg", lo: "$lo", hi: "$hi" } }
                """)
        // Several keys make a document; HAVING names an output, an aggregate written again, or one not selected.
        #expect(try pipe("""
            SELECT c.country, tier, COUNT(*) FROM orders o JOIN customers c ON o.customerId = c._id GROUP BY c.country, o.tier
            HAVING COUNT(*) > 2 AND MAX(o.total) < 100 AND tier <> 'x' ORDER BY 3 DESC, country LIMIT 5 OFFSET 10
            """) == """
            { $lookup: { from: "customers", localField: "customerId", foreignField: "_id", as: "c" } }
            { $unwind: { path: "$c" } }
            { $group: { _id: { country: "$c.country", tier: "$tier" }, "COUNT(*)": { $sum: 1 }, _agg1: { $max: "$total" } } }
            { $match: { "COUNT(*)": { $gt: 2 }, _agg1: { $lt: 100 }, "_id.tier": { $ne: "x" } } }
            { $sort: { "COUNT(*)": -1, "_id.country": 1 } }
            { $skip: 10 }
            { $limit: 5 }
            { $project: { _id: 0, country: "$_id.country", tier: "$_id.tier", "COUNT(*)": "$COUNT(*)" } }
            """)
        #expect(try pipe("SELECT COUNT(*) AS n FROM t WHERE a = 1") == """
        { $match: { a: 1 } }
        { $group: { _id: null, n: { $sum: 1 } } }
        { $project: { _id: 0, n: "$n" } }
        """)
        #expect(try notes("SELECT COUNT(*) AS n FROM t") == [MongoSQL.emptyNote])
        #expect(try pipe("SELECT a AS k, COUNT(*) AS n FROM t GROUP BY k HAVING n >= 2 ORDER BY n")
                == """
                { $group: { _id: "$a", n: { $sum: 1 } } }
                { $match: { n: { $gte: 2 } } }
                { $sort: { n: 1 } }
                { $project: { _id: 0, k: "$_id", n: "$n" } }
                """, "GROUP BY and HAVING take the SELECT list's aliases")
        #expect(try pipe("SELECT a, COUNT(*) AS n FROM t GROUP BY 1").hasPrefix(#"{ $group: { _id: "$a""#), "and positions")
        #expect(try notes("SELECT a, COUNT(*) AS n FROM t GROUP BY a") == [MongoSQL.groupNote])
        #expect(try pipe("SELECT a.b, COUNT(*) AS n FROM t GROUP BY a.b, c.d").hasPrefix(#"{ $group: { _id: { b: "$a.b", c_d: "$c.d" }"#),
                "a key not selected is named after its path")
    }

    @Test func distinctGroupsOnTheSelectedFields() throws {
        #expect(try pipe("SELECT DISTINCT country FROM customers ORDER BY country DESC") == """
        { $group: { _id: "$country" } }
        { $sort: { _id: -1 } }
        { $project: { _id: 0, country: "$_id" } }
        """)
        #expect(try pipe("SELECT DISTINCT country, tier AS t FROM customers") == """
        { $group: { _id: { country: "$country", t: "$tier" } } }
        { $project: { _id: 0, country: "$_id.country", t: "$_id.t" } }
        """)
        #expect(try notes("SELECT DISTINCT country FROM customers") == [MongoSQL.groupNote])
    }

    @Test func orderByNamesAliasesAndPositions() throws {
        #expect(try pipe("SELECT a, b AS x FROM t ORDER BY 2 DESC, x, a ASC, c.d DESC, a") == """
        { $sort: { b: -1, a: 1, "c.d": -1 } }
        { $project: { _id: 0, a: "$a", x: "$b" } }
        """, "sorted before the $project, so fields not selected sort too; a repeated key keeps its first place")
        #expect(try pipe("SELECT * FROM t ORDER BY a LIMIT 3") == "{ $sort: { a: 1 } }\n{ $limit: 3 }")
    }

    @Test func limitAndOffsetInEveryForm() throws {
        #expect(try pipe("SELECT * FROM t LIMIT 3") == "{ $limit: 3 }")
        #expect(try pipe("SELECT * FROM t LIMIT 10, 3") == "{ $skip: 10 }\n{ $limit: 3 }")
        #expect(try pipe("SELECT * FROM t LIMIT 3 OFFSET 10") == "{ $skip: 10 }\n{ $limit: 3 }")
        #expect(try pipe("SELECT * FROM t LIMIT 3 OFFSET 0") == "{ $limit: 3 }")
    }

    @Test func notesOnlyWhenTheyApply() throws {
        #expect(try notes("SELECT * FROM t WHERE a > 1 AND b LIKE 'x%' AND c IS NULL").isEmpty)
        #expect(try notes("SELECT * FROM t WHERE a = 1") == [MongoSQL.equalityNote])
        #expect(try notes("SELECT * FROM t WHERE a IN (1)") == [MongoSQL.equalityNote])
        #expect(try notes("SELECT * FROM t WHERE a <> 1") == [MongoSQL.equalityNote, MongoSQL.negationNote])
        for sql in ["a NOT IN (1)", "a NOT LIKE 'x'", "NOT a > 1", "a NOT BETWEEN 1 AND 2"] {
            #expect(try notes("SELECT * FROM t WHERE " + sql).contains(MongoSQL.negationNote), "\(sql)")
        }
    }

    @Test func notesWhenTheSampleHoldsAnotherType() throws {
        let orders = MongoSample(schema: MongoSchema(sample: [
            BSONDocument([("createdAt", .datetime(0)), ("qty", .int32(1)), ("items", .array([.document(BSONDocument([("sku", .string("a"))]))]))]),
            BSONDocument([("createdAt", .datetime(1)), ("qty", .double(2)), ("items", .array([]))]),
        ]))
        let customers = MongoSample(schema: MongoSchema(sample: [BSONDocument([("_id", .objectId(BSONObjectId.generate()))])]))
        let sample: (String) -> MongoSample? = { ["orders": orders, "customers": customers][$0] }
        #expect(try notes("SELECT * FROM orders WHERE createdAt >= '2024-01-01'", sample: sample)
                == ["createdAt is mostly date in orders's sample but is compared with text here: MongoDB never converts types, so this may find nothing"])
        #expect(try notes("SELECT * FROM orders WHERE createdAt >= DATE '2024-01-01' AND qty > 1.5 AND items.sku = 'a'", sample: sample)
                == [MongoSQL.equalityNote], "numbers of any type match; array elements' paths are found")
        #expect(try notes("SELECT * FROM orders o JOIN customers c ON o.customerId = c._id WHERE c._id = 'cc01' AND x = 1", sample: sample)
                .contains("c._id is mostly ObjectId in customers's sample but is compared with text here: MongoDB never converts types, so this may find nothing"))
        #expect(try notes("SELECT * FROM orders WHERE qty > 1", sample: nil).isEmpty)
    }

    @Test func refusalsNameThePartAndWhereItIs() {
        let cases: [(sql: String, message: String, part: String)] = [
            ("SELECT * FROM t WHERE a IN (SELECT b FROM u)", "Subqueries aren't translated: use Stages", "a IN (SELECT b FROM u)"),
            ("SELECT * FROM t WHERE EXISTS (SELECT 1 FROM u)", "Subqueries aren't translated: use Stages", "EXISTS (SELECT 1 FROM u)"),
            ("SELECT * FROM (SELECT * FROM u) x", "Subqueries aren't translated: use Stages", "(SELECT * FROM u) x"),
            ("WITH x AS (SELECT 1) SELECT * FROM x", "WITH isn't translated: use Stages", "x AS (SELECT 1)"),
            ("SELECT a FROM t UNION SELECT a FROM u", "UNION isn't translated: use Stages", "SELECT a FROM u"),
            ("SELECT CASE WHEN a = 1 THEN 2 END FROM t", "CASE isn't translated: use Stages", "CASE WHEN a = 1 THEN 2 END"),
            ("SELECT ROW_NUMBER() OVER (ORDER BY a) FROM t", "Window functions aren't translated: use Stages", "ROW_NUMBER() OVER (ORDER BY a)"),
            ("SELECT a + 1 FROM t", "Expressions in SELECT aren't translated: name fields, or use Stages", "a + 1"),
            ("SELECT UPPER(a) FROM t", "Expressions in SELECT aren't translated: name fields, or use Stages", "UPPER(a)"),
            ("SELECT * FROM o JOIN c ON o.x = c.y AND o.z = c.w", "ON is translated only as one equality of two fields: a.x = b.y", "o.x = c.y AND o.z = c.w"),
            ("SELECT * FROM o JOIN c ON o.x = 1", "ON is translated only as one equality of two fields: a.x = b.y", "o.x = 1"),
            ("SELECT * FROM o JOIN c ON o.x = o.y", "ON must compare a field of c with one of an earlier collection", "o.x = o.y"),
            ("SELECT * FROM o RIGHT JOIN c ON o.x = c.y", "RIGHT JOIN isn't translated: swap the collections and use LEFT JOIN", "RIGHT JOIN"),
            ("SELECT * FROM o FULL JOIN c ON o.x = c.y", "FULL JOIN isn't translated: MongoDB has no full join", "FULL"),
            ("SELECT * FROM o NATURAL JOIN c", "NATURAL JOIN isn't translated: use JOIN or LEFT JOIN with ON", "NATURAL JOIN"),
            ("SELECT * FROM o CROSS JOIN c", "CROSS JOIN isn't translated: use JOIN or LEFT JOIN with ON", "CROSS JOIN"),
            ("SELECT * FROM o JOIN c USING (x)", "USING isn't translated: write ON a.x = b.y", "JOIN"),
            ("SELECT * FROM o, c", "A comma between collections isn't translated: use JOIN … ON", "c"),
            ("SELECT COUNT(DISTINCT a) FROM t", "COUNT(DISTINCT …) isn't translated: use Stages", "COUNT(DISTINCT a)"),
            ("SELECT COUNT(a) FROM t", "COUNT(field) isn't translated: use COUNT(*) with WHERE field IS NOT NULL", "COUNT(a)"),
            ("SELECT * FROM t WHERE a LIKE 'x!%' ESCAPE '!'", "ESCAPE isn't translated: LIKE takes \\ before % or _", "'!'"),
            ("DELETE FROM t", "Only SELECT is translated: DELETE isn't", "DELETE FROM t"),
            ("UPDATE t SET a = 1", "Only SELECT is translated: UPDATE isn't", "UPDATE t SET a = 1"),
            ("SELECT * FROM t;  SELECT 1", "Only one statement is translated at a time", "SELECT 1"),
            ("SELECT * FROM t WHERE", "Expected a value", ""),
            ("SELECT * FROM t WHERE a = b", "Comparing two fields isn't translated: use Stages", "a = b"),
            ("SELECT * FROM t WHERE a = NULL", "A comparison with NULL is never true in SQL: use IS NULL or IS NOT NULL", "a = NULL"),
            ("SELECT * FROM t WHERE a IN (1, NULL)", "NULL in IN (…) matches nothing in SQL: use IS NULL", "NULL"),
            ("SELECT * FROM t WHERE a REGEXP 'x'", "REGEXP isn't translated: use LIKE, or Stages", "REGEXP"),
            ("SELECT * FROM t WHERE a", "A condition is needed here, such as name = 'value'", "a"),
            ("SELECT * FROM t WHERE LOWER(a) = 'x'", "A comparison needs a field on one side", "LOWER(a) = 'x'"),
            ("SELECT * FROM t WHERE COUNT(*) > 1", "Aggregates go in HAVING, not WHERE", "COUNT(*)"),
            ("SELECT * FROM t WHERE a = DATE '2024-02-30'", "2024-02-30 isn't a date", "DATE '2024-02-30'"),
            ("SELECT * FROM t WHERE a = TIME '10:00:00'", "TIME '…' isn't translated: MongoDB keeps dates with times", "TIME '10:00:00'"),
            ("SELECT * FROM t WHERE a = ObjectId('xyz')", "ObjectId('…') takes 24 hexadecimal digits", "ObjectId('xyz')"),
            ("SELECT * FROM t WHERE a = 0x1F", "0x1F isn't a value translated here: use text, a number, TRUE, FALSE, DATE '…', TIMESTAMP '…' or ObjectId('…')", "0x1F"),
            ("SELECT * FROM t WHERE a IS TRUE", "IS TRUE isn't translated: use = TRUE or = FALSE", "a IS TRUE"),
            ("SELECT a, COUNT(*) AS n FROM t GROUP BY b", "a isn't in GROUP BY: group by it, or use an aggregate such as MAX(a)", "a"),
            ("SELECT a FROM t GROUP BY a HAVING b > 1", "b isn't in GROUP BY: after grouping only its fields and aggregates are left", "b"),
            ("SELECT a FROM t HAVING a > 1", "HAVING without GROUP BY isn't translated: use WHERE", "a > 1"),
            ("SELECT a FROM t GROUP BY a WITH ROLLUP", "WITH ROLLUP isn't translated: use Stages", "SELECT a FROM t GROUP BY a WITH ROLLUP"),
            ("SELECT DISTINCT a, COUNT(*) FROM t", "DISTINCT with aggregates isn't translated", "COUNT(*)"),
            ("SELECT a.b, c.b FROM t", "Two columns are named b: give one another name with AS", "c.b"),
            ("SELECT SUM(o.total) FROM orders o", "SUM(o.total) can't be a field name in MongoDB: give it a name with AS", "SUM(o.total)"),
            ("SELECT *, a FROM t", "* with other columns isn't translated: name the fields", "*"),
            ("SELECT c.* FROM o JOIN c ON o.x = c.y", "c.* isn't translated: name the fields, or use *", "c.*"),
            ("SELECT * FROM shop.orders", "A database name isn't translated: the query runs in this database", "shop.orders"),
            ("SELECT 1", "FROM is needed: it names the collection", "SELECT 1"),
            ("SELECT * FROM t ORDER BY a + 1", "ORDER BY takes names, aliases and positions, not expressions", "a + 1"),
            ("SELECT * FROM t ORDER BY 1", "ORDER BY a position needs a SELECT list, not *", "1"),
            ("SELECT a FROM t ORDER BY 2", "2 isn't a column of the SELECT list", "2"),
            ("SELECT * FROM t LIMIT 0", "LIMIT 0 returns nothing", "0"),
            ("SELECT * FROM t LIMIT ?", "LIMIT and OFFSET take whole numbers", "?"),
            ("SELECT * FROM o JOIN c ON o.x = d.y JOIN d ON d.z = c.z", "d can't be named here: use its alias, of a collection joined before this", "d"),
            ("SELECT * FROM orders o WHERE orders.a = 1", "orders can't be named here: use its alias, of a collection joined before this", "orders"),
            ("SELECT * FROM t WHERE $a = 1", "A field name can't be empty or start with $", "$a"),
        ]
        for (sql, message, part) in cases {
            let found = refusal(sql)
            #expect(found?.message == message, "\(sql)")
            if let found, !part.isEmpty {
                #expect((sql as NSString).substring(with: NSRange(location: found.offset, length: found.range.count)) == part, "\(sql)")
            }
        }
    }

    @Test func selectIntoAndLockingAreRefused() {
        #expect(refusal("SELECT a FROM t INTO OUTFILE '/x'")?.message == "SELECT … INTO isn't translated: nothing here writes")
        #expect(refusal("SELECT a FROM t FOR UPDATE")?.message == "FOR UPDATE, LOCK and PROCEDURE aren't translated")
    }

    @Test func theMySQLParserReadsDeepPaths() throws {
        let name = SQLParser.parse("SELECT o.a.b.c FROM t o").first?.query?.blocks.first?.items.first?.expr.name
        #expect(name?.parts.map(\.value) == ["o", "a", "b", "c"])
        #expect(try pipe("SELECT o.a.b.c FROM t o WHERE o.a.b.d = 1")
                == "{ $match: { \"a.b.d\": 1 } }\n{ $project: { _id: 0, c: \"$a.b.c\" } }")
    }
}

/// `shop`'s questions in SQL, against the oracle's answers.
@Suite(.serialized, .enabled(if: MongoLab.enabled, "Mongo lab: AIRSQL_MONGO_LAB=1 ./test.sh --filter Mongo"))
struct MongoSQLLabTests {
    static func answers() throws -> [String: Any] {
        let seed = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("testenv/mongo/seed/shop-answers.json")
        let all = try JSONSerialization.jsonObject(with: Data(contentsOf: seed)) as! [String: Any]
        return all.mapValues { ($0 as? [String: Any])?["answer"] as Any }
    }

    static func number(_ value: BSONValue?) -> Double? {
        switch value {
        case .int32(let n)?: return Double(n)
        case .int64(let n)?: return Double(n)
        case .double(let n)?: return n
        case .decimal128(let n)?: return Double(n.description)
        default: return nil
        }
    }

    static func cents(_ value: Any?) -> Int? { (value as? NSNumber).map { Int(($0.doubleValue * 100).rounded()) } }

    @Test(arguments: AgentMongoLabTests.Server.allCases)
    func shopQuestionsInSQLGiveTheOraclesAnswers(_ server: AgentMongoLabTests.Server) async throws {
        let target = try await AgentMongoLabTests.target(server)
        let mongo = try #require(target.mongo)
        defer { Task { await mongo.close() } }
        let session = try await mongo.session(.data)
        func run(_ sql: String) async throws -> [BSONDocument] {
            let translation = try MongoSQL.translate(sql)
            return try await session.all(session.aggregate(database: "shop", collection: translation.collection, pipeline: translation.pipeline))
        }
        let answers = try Self.answers()
        let paid = "('paid', 'shipped', 'delivered')"

        // GROUP BY with COUNT, ORDER BY an alias, LIMIT.
        let status = try await run("SELECT status, COUNT(*) AS orders FROM orders GROUP BY status ORDER BY orders DESC LIMIT 1")
        let q02 = answers["q02_commonest_status"] as! [String: Any]
        #expect(status.count == 1 && status[0]["status"] == .string(q02["status"] as! String) && Self.number(status[0]["orders"]) == Double(q02["orders"] as! Int))

        // SUM over IN and a date range.
        let march = try await run("""
            SELECT SUM(total) AS revenue FROM orders WHERE status IN \(paid)
            AND createdAt >= TIMESTAMP '2024-03-01 00:00:00' AND createdAt < DATE '2024-04-01'
            """)
        #expect(march.count == 1 && Self.number(march[0]["revenue"]).map { Int(($0 * 100).rounded()) } == Self.cents(answers["q03_paid_revenue_march_2024"]))

        // A JOIN, a GROUP BY on two keys, SUM, ORDER BY + LIMIT.
        let spender = try await run("""
            SELECT c._id AS customerId, c.name, SUM(o.total) AS spent FROM orders o JOIN customers c ON o.customerId = c._id
            WHERE o.status IN \(paid) GROUP BY c._id, c.name ORDER BY spent DESC LIMIT 1
            """)
        let q07 = answers["q07_top_spender"] as! [String: Any]
        #expect(spender.count == 1 && spender[0]["name"] == .string(q07["name"] as! String))
        if case .objectId(let id)? = spender.first?["customerId"] { #expect(id.hex == q07["customerId"] as? String) } else { Issue.record("no customerId") }
        #expect(Self.number(spender.first?["spent"]).map { Int(($0 * 100).rounded()) } == Self.cents(q07["spent"]))

        // HAVING with the aggregate written again, AVG, ORDER BY a joined field.
        let ratings = try await run("""
            SELECT p.category, COUNT(*) AS reviews, AVG(r.rating) AS average FROM reviews r JOIN products p ON r.productSku = p.sku
            GROUP BY p.category HAVING COUNT(*) >= 20 ORDER BY p.category
            """)
        let q08 = answers["q08_avg_rating_by_category"] as! [[String: Any]]
        #expect(ratings.map { $0["category"] } == q08.map { .string($0["category"] as! String) })
        #expect(ratings.map { Self.number($0["reviews"]) } == q08.map { Double($0["reviews"] as! Int) })
        #expect(ratings.map { Self.number($0["average"]).map { ($0 * 100).rounded() / 100 } } == q08.map { ($0["average"] as! NSNumber).doubleValue })

        // LEFT JOIN: the orders whose customer doesn't exist.
        let orphans = try await run("SELECT COUNT(*) AS n FROM orders o LEFT JOIN customers c ON o.customerId = c._id WHERE c._id IS NULL")
        #expect(Self.number(orphans.first?["n"]) == Double(answers["q10_orphan_orders"] as! Int))

        // LIKE ignoring case, ORDER BY a field not selected.
        let theirs = try await run("""
            SELECT o._id FROM orders o JOIN customers c ON o.customerId = c._id WHERE c.name LIKE 'customer 42' ORDER BY o.createdAt DESC
            """)
        let q11 = answers["q11_propose_in_tab"] as! [String: Any]
        #expect(theirs.map { doc -> String in if case .objectId(let id)? = doc["_id"] { return id.hex }; return "" } == q11["orderIds"] as! [String])
        #expect(theirs.allSatisfy { $0.keys == ["_id"] })
    }
}
