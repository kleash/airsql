import AirSQLCore
import Testing

/// The reason a statement is refused, or nil when it's read-only.
func refusal(_ sql: String, noBackslashEscapes: Bool = false) -> String? {
    if case .refused(let reason) = ReadOnlyClassifier.classify(sql, noBackslashEscapes: noBackslashEscapes) {
        return reason
    }
    return nil
}

struct ReadOnlyClassifierTests {
    @Test func acceptsTheReadStatements() {
        for sql in ["SELECT 1", "select 1;", "WITH a AS (SELECT 1) SELECT * FROM a", "SHOW TABLES", "DESCRIBE t",
                    "DESC t", "EXPLAIN t", "EXPLAIN SELECT 1", "(SELECT 1) UNION (SELECT 2)", "EXPLAIN FOR CONNECTION 7"] {
            #expect(refusal(sql) == nil, "\(sql)")
        }
    }

    @Test func refusesOtherStatementsByName() {
        #expect(refusal("UPDATE t SET a = 1") == "UPDATE isn't a read-only statement; only SELECT, WITH … SELECT, SHOW, "
            + "DESCRIBE and EXPLAIN are")
        #expect(refusal("'x'")?.hasPrefix("This isn't a read-only statement") == true)
    }

    @Test func oneStatementOnly() {
        #expect(refusal("SELECT 1; DROP TABLE t") == "It holds more than one statement; send one at a time")
        #expect(refusal("SELECT ';' ; -- done") == nil)
        #expect(refusal("SELECT 1 /*!; DROP TABLE t */") == "It holds more than one statement; send one at a time")
        #expect(refusal("") == "There's no statement in it")
        #expect(refusal(" -- nothing\n;") == "There's no statement in it")
    }

    @Test func intoLocksHintsAndTemporaryTables() {
        #expect(refusal("SELECT a INTO @x FROM t") == "INTO writes the result to a file or to variables")
        #expect(refusal("SELECT * FROM t FOR UPDATE") == "FOR UPDATE locks the rows it reads")
        #expect(refusal("SELECT * FROM t for share") == "FOR SHARE locks the rows it reads")
        #expect(refusal("SELECT * FROM t LOCK IN SHARE MODE") == "LOCK IN SHARE MODE locks the rows it reads")
        #expect(refusal("SELECT /*+ MAX_EXECUTION_TIME(0) */ 1")
            == "Optimizer hints (/*+ … */) can lift the server's limits, such as MAX_EXECUTION_TIME")
        #expect(refusal("CREATE TEMPORARY TABLE x (a INT)")?.hasPrefix("CREATE isn't a read-only statement") == true)
        #expect(refusal("SELECT * FROM t /*!50000 TEMPORARY */")
            == "Temporary tables can be written even in a read-only transaction")
        #expect(refusal("SELECT * FROM t FOR SYSTEM_TIME ALL") == nil)
        #expect(refusal("SELECT SUBSTRING(s FROM 1 FOR 2) FROM t") == nil)
    }

    /// A version-gated comment above the server's version is skipped whole by the server, which then runs the code
    /// after its */. A quote in such a comment must not open a string that swallows the */ and hides that code.
    @Test func versionGatedCommentCannotHideCode() {
        #expect(refusal("SELECT 1 /*!99999 ' */, GET_LOCK('x', 0) -- ' */")
            == "GET_LOCK() isn't on the list of functions read-only queries may call")
        #expect(refusal("SELECT 1 /*M!999999 ' */, SLEEP(5) -- ' */")
            == "SLEEP() isn't on the list of functions read-only queries may call")
        #expect(refusal("SELECT 1 /*!99999 ' */ INTO OUTFILE '/tmp/x' -- ' */")
            == "INTO writes the result to a file or to variables")
        // A body that runs as code on a server at or over the gate is still read as code.
        #expect(refusal("SELECT /*!40001 SQL_NO_CACHE */ 1") == nil)
        #expect(refusal("SELECT 1 /*!50000 + 2 */") == nil)
        #expect(refusal("SELECT 1 /*!50000 , SLEEP(5) */")
            == "SLEEP() isn't on the list of functions read-only queries may call")
    }

    @Test func functionsMustBeOnTheList() {
        #expect(refusal("SELECT sleep (1)") == "sleep() isn't on the list of functions read-only queries may call")
        #expect(refusal("SELECT ſum(a) FROM t") == "ſum() isn't on the list of functions read-only queries may call")
        #expect(refusal("SELECT shop.bonus(1)") == "shop.bonus() calls a stored function, which can change data")
        #expect(refusal("SELECT `concat`('a')")
            == "It calls a function by a quoted name (`concat`), which can reach a stored function")
        #expect(refusal("SELECT COUNT(*), Concat(a, b), json_extract(j, '$.a') FROM t") == nil)
        #expect(refusal("SELECT CAST(a AS DECIMAL(10,2)), x IN (1), EXISTS (SELECT 1) FROM t") == nil)
    }

    @Test func columnListsAreNotCalls() {
        #expect(refusal("WITH RECURSIVE c (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c WHERE n < 5) SELECT n FROM c") == nil)
        #expect(refusal("SELECT * FROM (SELECT 1, 2) AS d (a, b)") == nil)
        #expect(refusal("SELECT * FROM (WITH `c` (n) AS (SELECT 1) SELECT n FROM c) AS x") == nil)
    }

    @Test func withMustLeadToSelect() {
        #expect(refusal("WITH a AS (SELECT 1) DELETE FROM t") == "Only WITH … SELECT is read-only, not WITH … DELETE")
        #expect(refusal("WITH a AS (SELECT 1)") == "WITH needs a SELECT after its list")
        #expect(refusal("WITH a SELECT 1") == "Its WITH list isn't in a form this check can read")
        #expect(refusal("WITH a AS (SELECT (1) SELECT 1") == "Its parentheses don't match")
    }

    @Test func explainForms() {
        #expect(refusal("EXPLAIN ANALYZE SELECT 1") == "EXPLAIN ANALYZE runs the statement it explains")
        #expect(refusal("EXPLAIN FORMAT=JSON ANALYZE SELECT 1") == "EXPLAIN ANALYZE runs the statement it explains")
        #expect(refusal("DESCRIBE DELETE FROM t")
            == "EXPLAIN DELETE explains a write; only the plans of SELECT statements are read-only here")
        #expect(refusal("EXPLAIN DROP TABLE t") == "EXPLAIN needs a table or a SELECT")
        #expect(refusal("EXPLAIN") == "EXPLAIN needs a table or a SELECT")
        #expect(refusal("EXPLAIN FOR CONNECTION 7, 8")
            == "Only EXPLAIN FOR CONNECTION and a connection number is read-only here")
        #expect(refusal("EXPLAIN EXTENDED SELECT 1") == nil)
        #expect(refusal("EXPLAIN FORMAT = TREE SELECT 1") == nil)
        #expect(refusal("DESCRIBE `select`") == nil)
    }

    @Test func sequencesAndAssignments() {
        #expect(refusal("SELECT NEXT VALUE FOR s") == "NEXT VALUE FOR moves a sequence on")
        #expect(refusal("SELECT s.nextval") == "NEXTVAL moves a sequence on")
        #expect(refusal("SELECT @a := 1") == "It assigns a variable (:=)")
        #expect(refusal("SELECT PREVIOUS VALUE FOR s") == nil)
        #expect(refusal("SELECT * FROM t OFFSET 5 ROWS FETCH NEXT 10 ROWS ONLY") == nil)
    }

    @Test func backslashesFollowTheSessionsMode() {
        let oBrien = #"SELECT * FROM t WHERE name = 'O\'Brien'"#
        #expect(refusal(oBrien) == nil)
        #expect(refusal(oBrien, noBackslashEscapes: true) == "A string, quoted name or comment in it isn't closed")
        #expect(refusal(#"SELECT 'C:\'"#, noBackslashEscapes: true) == nil)
        let hidden = #"SELECT 'x\'; DROP TABLE t; -- '"#
        #expect(refusal(hidden) == nil)  // one string, as the server reads it with backslash escapes
        #expect(refusal(hidden, noBackslashEscapes: true) == "It holds more than one statement; send one at a time")
    }

    @Test func doubleQuotedTextWithABackslashIsRefused() {
        let reason = "Double-quoted text with a backslash in it is a name under ANSI_QUOTES, where the backslash "
            + "escapes nothing; use single quotes"
        for noBackslashEscapes in [false, true] {
            #expect(refusal(#"SELECT "say \"hi\"""#, noBackslashEscapes: noBackslashEscapes) == reason)
            #expect(refusal(#"SELECT "C:\\temp", @"a\b""#, noBackslashEscapes: noBackslashEscapes) == reason)
            #expect(refusal(#"SELECT "say ""hi""", 'C:\\temp'"#, noBackslashEscapes: noBackslashEscapes) == nil)
        }
    }

    @Test func brokenText() {
        #expect(refusal("SELECT 'abc") == "A string, quoted name or comment in it isn't closed")
        #expect(refusal("SELECT 1 /* note") == "A string, quoted name or comment in it isn't closed")
        #expect(refusal("SELECT 1 /*!50000 , 2") == "A string, quoted name or comment in it isn't closed")
        #expect(refusal("SELECT 1\u{0}") == "It contains a NUL character")
    }

    @Test func schemaSessionStatisticsSetting() {
        #expect(refusal("SET SESSION information_schema_stats_expiry = 0") == nil)
        #expect(refusal("set session INFORMATION_SCHEMA_STATS_EXPIRY=0;") == nil)
        #expect(refusal("SET GLOBAL information_schema_stats_expiry = 0") != nil)
        #expect(refusal("SET SESSION information_schema_stats_expiry = 1") != nil)
        #expect(refusal("SET SESSION max_execution_time = 0") != nil)
    }
}
