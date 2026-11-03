/// Statements the read-only check must refuse (plan §2.8, R4), by the trick they try. Second half in
/// ReadOnlyCorpus+Attacks2.swift.
enum AttackCorpus {
    /// Refused whatever the session's NO_BACKSLASH_ESCAPES.
    static var all: [String] { filesAndVariables + holdingTheServer + functionsThatAreNotBuiltIn + commentTricks
        + backslashesInDoubleQuotes + executableComments + hints + withAndExplain + locks + sequencesAndAssignments
        + temporaryTables + severalStatements + otherStatements + brokenText }

    static let filesAndVariables = [
        "SELECT * FROM users INTO OUTFILE '/tmp/users.txt'",
        "SELECT * INTO OUTFILE '/tmp/x' FIELDS TERMINATED BY ',' FROM users",
        "SELECT 0x3c3f706870 INTO DUMPFILE '/var/www/shell.php'",
        "SELECT name INTO @who FROM users LIMIT 1",
        "SELECT name FROM users LIMIT 1 INTO @who",
        "SELECT 1 UNION SELECT name FROM users INTO OUTFILE '/tmp/x'",
        "SELECT * FROM (SELECT 1 INTO @x) AS t",
        "EXPLAIN FORMAT=JSON INTO @plan SELECT 1",
        "SELECT LOAD_FILE('/etc/passwd')",
        "SELECT load_file(0x2f6574632f706173737764)",
        "SELECT 1 UNION ALL SELECT LOAD_FILE('/etc/hosts')",
    ]

    static let holdingTheServer = [
        "SELECT SLEEP(10)",
        "select sleep (10)",
        "SELECT SLEEP/**/(10)",
        "SELECT SLEEP#\n(10)",
        "SELECT SLEEP-- \n(10)",
        "sElEcT sLeEp(1)",
        "SELECT * FROM users WHERE SLEEP(5) = 0",
        "SELECT IF(1 = 1, SLEEP(5), 0)",
        "SELECT EXTRACTVALUE(1, CONCAT(0x7e, (SELECT SLEEP(1))))",
        "SELECT {fn sleep(5)}",
        "SELECT BENCHMARK(100000000, MD5('x'))",
        "SELECT GET_LOCK('deploy', 10)",
        "SELECT RELEASE_LOCK('deploy')",
        "SELECT RELEASE_ALL_LOCKS()",
        "SELECT IS_FREE_LOCK('deploy')",
        "SELECT IS_USED_LOCK('deploy')",
        "SELECT MASTER_POS_WAIT('binlog.000001', 4)",
        "SELECT SOURCE_POS_WAIT('binlog.000001', 4, 60)",
        "SELECT WAIT_FOR_EXECUTED_GTID_SET('3E11FA47-71CA-11E1-9E33-C80AA9429562:1-5', 60)",
        "SELECT MASTER_GTID_WAIT('0-1-100', 60)",
        "SELECT LAST_INSERT_ID(42)",
        "SELECT * FROM users PROCEDURE ANALYSE()",
        "SHOW TABLES WHERE SLEEP(5)",
        "SHOW DATABASES WHERE BENCHMARK(1000000000, 1)",
        "SELECT \u{17F}leep(5)",
        "SELECT SLEEP\u{A0}(5)",
    ]

    static let functionsThatAreNotBuiltIn = [
        "SELECT sys_exec('id')",
        "SELECT sys_eval('cat /etc/passwd')",
        "SELECT lib_mysqludf_sys_info()",
        "SELECT audit_log_filter_set_filter('log_all', '{\"filter\": {\"log\": true}}')",
        "SELECT version_tokens_set('tok=1')",
        "SELECT keyring_key_store('key', 'AES', 'secret')",
        "SELECT group_replication_set_as_primary('00000000-0000-0000-0000-000000000000')",
        "SELECT service_get_write_locks('ns', 'lock', 10)",
        "SELECT my_udf(1)",
        "SELECT shop.calculate_bonus(1)",
        "SELECT `shop`.`calculate_bonus`(1)",
        "SELECT sys.format_bytes(1024)",
        "SELECT shop . concat('a')",
        "SELECT shop./**/concat('a')",
        "SELECT shop.5concat(1)",
        "SELECT 5concat(1)",
        "SELECT 0x1Gconcat(1)",
        "SELECT `concat`('a', 'b')",
        "SELECT \"concat\"('a', 'b')",
        "SELECT 'concat'('a')",
        "SELECT nvl(a, 0) FROM t",
        "SELECT to_char(NOW())",
        "SELECT LASTVAL(order_seq)",
    ]

    static let commentTricks = [
        "SELECT 1 --1\n, SLEEP(5)",
        "SELECT 1--1\n, LOAD_FILE('/etc/passwd')",
        "SELECT 1 --x\nUNION SELECT LOAD_FILE('/etc/passwd')",
        "SELECT 1-- -\n; DROP TABLE users",
        "SELECT 1 # \n; DROP TABLE users",
        "SELECT 1 /* */; DROP TABLE users",
        "SELECT 1 /* x */ INTO OUTFILE '/tmp/x'",
        "SELECT 1; -- \nDROP TABLE users",
        "SELECT 1 /* ; DROP TABLE users",
        "SELECT 1 # \u{0}\n, SLEEP(5)",
    ]

    /// Strings that end elsewhere when backslashes escape: refused on a session with backslash escapes, where the
    /// server runs what a reading without escapes would take for a string.
    static let againstBackslashEscapes = [
        #"SELECT '\'' , SLEEP(5) , '\''"#,
        #"SELECT * FROM t WHERE a = '\'' UNION SELECT LOAD_FILE('/etc/passwd') -- '"#,
        #"SELECT 'x\\' , SLEEP(1) -- '"#,
    ]

    /// The other way round: refused on a NO_BACKSLASH_ESCAPES session.
    static let againstNoBackslashEscapes = [
        #"SELECT 'a\' , SLEEP(5) , '\'"#,
        #"SELECT 1 FROM t WHERE a = '\' OR 1=1 INTO OUTFILE '/tmp/x' -- '"#,
        #"SELECT 1 FROM t WHERE a = '\\\' UNION SELECT LOAD_FILE('/etc/passwd') -- '"#,
        #"SELECT * FROM users WHERE name = 'x\'; DROP TABLE users; -- '"#,
        #"SELECT 'x\\' , SLEEP(1) -- '"#,
    ]

    /// Under ANSI_QUOTES "…" is a name and its backslashes escape nothing, whatever NO_BACKSLASH_ESCAPES says.
    static let backslashesInDoubleQuotes = [
        #"SELECT "\"" , SLEEP(5) , """"#,
        #"SELECT "a\" , SLEEP(5) , "\""#,
        #"SELECT "x\" , LOAD_FILE('/etc/passwd') , \"" FROM t"#,
        #"SELECT @"v\" , SLEEP(1) , \"""#,
    ]

    static let executableComments = [
        "SELECT 1 /*!50000 , SLEEP(5) */",
        "SELECT 1 /*!99999 INTO OUTFILE '/tmp/x' */",
        "SELECT 1 /*M!100100 , LOAD_FILE('/etc/passwd') */",
        "SELECT 1 /*!; DROP TABLE users */",
        "SELECT 1 /*M!; SET GLOBAL read_only = 0 */",
        "/*!50000 DROP TABLE users */",
        "/*!40101 SET @x = 1 */",
        "/*!50000 SELECT */ 1 /*!50000 FOR UPDATE */",
        "SELECT * FROM users /*!50000 LOCK IN SHARE MODE */",
        "SELECT /*!*/ SLEEP(1)",
        "SELECT 1 /*! INTO @x */",
        "SELECT 1 /*!50000 /*+ MAX_EXECUTION_TIME(0) */ */",
        "SELECT 1 /*!50000 , SLEEP(5)",
        "SELECT /*!50000 sys_exec */('id')",
        "SELECT 1 /*!50000 UNION SELECT LOAD_FILE('/etc/passwd') */",
        // A quote in a version-gated comment whose version the server is under: the server skips the whole comment and
        // runs what comes after its */, so the lexer must not let the quote open a string that swallows the */.
        "SELECT 1 /*!99999 ' */, GET_LOCK('x', 0) -- ' */",
        "SELECT 1 /*M!999999 ' */, GET_LOCK('x', 0) -- ' */",
        "SELECT 1 AS one /*!99999 ' */, SLEEP(5) AS l -- ' */",
        "SELECT 1 /*!99999 ' */ INTO OUTFILE '/tmp/x' -- ' */",
        "SELECT 1 /*!99999 ' */ , LOAD_FILE('/etc/passwd') AS f -- ' */",
        "SELECT 1 /*!99999 \" */, GET_LOCK('x', 0) -- \" */",
        "SELECT 1 /*!99999 ` */, GET_LOCK('x', 0) -- ` */",
        "/*!99999 ' */ SELECT SLEEP(5) -- ' */",
    ]

    static let hints = [
        "SELECT /*+ MAX_EXECUTION_TIME(100000000) */ * FROM users",
        "SELECT /*+ SET_VAR(max_execution_time = 0) */ 1",
        "SELECT /*+ SET_VAR(transaction_read_only = OFF) */ 1",
        "SELECT /*+ RESOURCE_GROUP(batch) */ 1",
        "SELECT /*+ BKA(users) NO_ICP(users) */ * FROM users",
        "(SELECT /*+ MAX_EXECUTION_TIME(0) */ 1)",
        "SELECT 1 UNION SELECT /*+ MAX_EXECUTION_TIME(0) */ 2",
        "SET STATEMENT max_statement_time = 0 FOR SELECT SLEEP(100)",
        "SET SESSION max_execution_time = 0",
        "SET max_statement_time = 0",
        "SET GLOBAL information_schema_stats_expiry = 0",
        "SET SESSION information_schema_stats_expiry = 0; SELECT SLEEP(5)",
        "SET SESSION TRANSACTION READ WRITE",
    ]
}
