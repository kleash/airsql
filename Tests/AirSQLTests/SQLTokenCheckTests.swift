import AirSQLCore
import Testing

struct SQLTokenCheckTests {
    @Test func layoutAndReservedWordCaseMayChange() {
        #expect(SQLLexer.sameTokens("select a,b from t where x=1 order by a desc",
                                    "SELECT a, b\nFROM t\nWHERE x = 1\nORDER BY a DESC"))
        #expect(SQLLexer.sameTokens("SELECT 1 -- note\nFROM dual", "select 1   -- note\n  from dual"))
    }

    @Test func namesKeepTheirCase() {
        #expect(!SQLLexer.sameTokens("select * from users", "SELECT * FROM USERS"))
        #expect(!SQLLexer.sameTokens("select count(*) from t", "SELECT COUNT(*) FROM t"))  // COUNT isn't reserved
        #expect(!SQLLexer.sameTokens("SELECT * FROM shop.order", "SELECT * FROM shop.ORDER"))  // a name after a dot
        #expect(!SQLLexer.sameTokens("SELECT `select`", "SELECT `SELECT`"))
    }

    @Test func literalsCommentsAndExecutableCommentsStayExact() {
        #expect(!SQLLexer.sameTokens("SELECT 'a b'", "SELECT 'a  b'"))
        #expect(!SQLLexer.sameTokens("SELECT 1 -- note", "SELECT 1 --  note"))
        #expect(!SQLLexer.sameTokens("SELECT 1 /* a */", "SELECT 1 /*a*/"))
        #expect(!SQLLexer.sameTokens("/*!40101 SET x = 1 */", "/*!40101 set x = 1 */"))
        #expect(!SQLLexer.sameTokens("SELECT x'4142'", "SELECT x '4142'"))
    }

    @Test func tokensMayNotMergeSplitOrHide() {
        #expect(!SQLLexer.sameTokens("SELECT a b", "SELECT ab"))
        #expect(!SQLLexer.sameTokens("SELECT a <= b", "SELECT a < = b"))
        #expect(!SQLLexer.sameTokens("SELECT 1 - - 1", "SELECT 1 -- 1"))
        #expect(!SQLLexer.sameTokens("SELECT 1 -- c\nFROM t", "SELECT 1 -- c FROM t"))
        #expect(!SQLLexer.sameTokens("SELECT 1; SELECT 2", "SELECT 1 SELECT 2"))
    }

    @Test func delimiterBlocks() {
        let original = "DELIMITER ;;\nCREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END;;\nDELIMITER ;\nCALL p();"
        let reindented = "DELIMITER ;;\nCREATE PROCEDURE p()\nBEGIN\n  SELECT 1;\n  SELECT 2;\nEND;;\nDELIMITER ;\nCALL p();"
        #expect(SQLLexer.sameTokens(original, reindented))
        #expect(!SQLLexer.sameTokens(original, original.replacingOccurrences(of: "DELIMITER ;;", with: "DELIMITER ; ;")))
        #expect(!SQLLexer.sameTokens(original, original.replacingOccurrences(of: "END;;\nDELIMITER", with: "END;; DELIMITER")))
    }
}
