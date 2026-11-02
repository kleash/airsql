import AirSQLCore
import Testing

private func split(_ sql: String, noBackslashEscapes: Bool = false) -> [String] {
    SQLSplitter.statements(in: sql, noBackslashEscapes: noBackslashEscapes).map(\.sql)
}

struct SQLSplitterTests {
    @Test func splitsOnSemicolons() {
        #expect(split("SELECT 1; SELECT 2;") == ["SELECT 1", "SELECT 2"])
        #expect(split(";;SELECT 1;;\n;") == ["SELECT 1"])
        #expect(split("SELECT 1; SELECT 2") == ["SELECT 1", "SELECT 2"])
        #expect(split("  \n-- nothing to run\n") == [])
    }

    @Test func semicolonsInStringsNamesAndCommentsDoNotSplit() {
        let sql = "SELECT ';' AS a; -- x; y\nSELECT \"b;c\" /* ; */ FROM `d;e`; # f;\nSELECT 3"
        #expect(split(sql) == ["SELECT ';' AS a", "SELECT \"b;c\" /* ; */ FROM `d;e`", "SELECT 3"])
    }

    @Test func rangesLeaveOutCommentsAroundAndTheDelimiter() {
        let sql = "-- name: orders\nSELECT * FROM orders /* all */;\nSELECT 'é😀'"
        let statements = SQLSplitter.statements(in: sql)
        #expect(statements.map(\.range) == [16..<36, 48..<60])
        #expect(statements.map(\.end) == [47, 60])
    }

    @Test func backslashModeDecidesWhereStringsEnd() {
        #expect(split(#"SELECT 'a\'; SELECT 2"#) == [#"SELECT 'a\'; SELECT 2"#])
        #expect(split(#"SELECT 'a\'; SELECT 2"#, noBackslashEscapes: true) == [#"SELECT 'a\'"#, "SELECT 2"])
    }

    @Test func procedureWithDelimiterLines() {
        let sql = """
            DELIMITER //
            CREATE PROCEDURE p()
            BEGIN
              SELECT 1; -- not the end
              SELECT ';' ;
            END//
            delimiter ;
            CALL p();
            SELECT 4/2;
            """
        #expect(split(sql) == [
            "CREATE PROCEDURE p()\nBEGIN\n  SELECT 1; -- not the end\n  SELECT ';' ;\nEND", "CALL p()", "SELECT 4/2",
        ])
    }

    @Test func delimiterInsideAWord() {
        let sql = """
            DELIMITER $$
            CREATE TRIGGER t BEFORE INSERT ON x FOR EACH ROW BEGIN SET NEW.a = 1; END$$
            DELIMITER ;
            SELECT 1
            """
        #expect(split(sql) == ["CREATE TRIGGER t BEFORE INSERT ON x FOR EACH ROW BEGIN SET NEW.a = 1; END", "SELECT 1"])
    }

    @Test func mysqldumpTriggerInExecutableComments() {
        let sql = """
            /*!40101 SET @saved_cs_client = @@character_set_client */;
            DELIMITER ;;
            /*!50003 CREATE*/ /*!50017 DEFINER=`app`@`%`*/ /*!50003 TRIGGER trg BEFORE INSERT ON t FOR EACH ROW BEGIN
              SET NEW.a = 1; SET NEW.b = ';';
            END */;;
            DELIMITER ;
            /*!40101 SET character_set_client = @saved_cs_client */;
            """
        #expect(split(sql) == [
            "/*!40101 SET @saved_cs_client = @@character_set_client */",
            "/*!50003 CREATE*/ /*!50017 DEFINER=`app`@`%`*/ /*!50003 TRIGGER trg BEFORE INSERT ON t FOR EACH ROW BEGIN\n"
                + "  SET NEW.a = 1; SET NEW.b = ';';\nEND */",
            "/*!40101 SET character_set_client = @saved_cs_client */",
        ])
    }

    @Test func delimiterOnlyCountsWhereAStatementStarts() {
        #expect(split("SELECT a,\ndelimiter\nFROM t; SELECT 2") == ["SELECT a,\ndelimiter\nFROM t", "SELECT 2"])
        #expect(split("SELECT 1 DELIMITER //") == ["SELECT 1 DELIMITER //"])
        #expect(split("/* c */ DELIMITER //\nSELECT 1//") == ["DELIMITER //\nSELECT 1//"])
        #expect(split("  DELIMITER //\nSELECT 1//SELECT 2") == ["SELECT 1", "SELECT 2"])
    }

    @Test func statementAtCaret() {
        let sql = "SELECT 1;  -- one\n\nSELECT 2;\n"
        func at(_ caret: Int) -> String? { SQLSplitter.statement(at: caret, in: sql)?.sql }
        #expect(at(0) == "SELECT 1")
        #expect(at(4) == "SELECT 1")
        #expect(at(9) == "SELECT 1")  // just after its ;
        #expect(at(17) == "SELECT 1")  // after the comment on its line
        #expect(at(18) == "SELECT 2")  // the blank line
        #expect(at(28) == "SELECT 2")
        #expect(at(29) == "SELECT 2")  // past the end
        #expect(SQLSplitter.statement(at: 0, in: "-- nothing") == nil)
    }
}
