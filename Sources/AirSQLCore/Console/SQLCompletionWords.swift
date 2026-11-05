/// The words completion offers where the grammar allows them, some of several words: ORDER BY, LEFT JOIN.
enum SQLCompletionWords {
    static let statementStart = ["SELECT", "INSERT INTO", "UPDATE", "DELETE FROM", "REPLACE INTO", "WITH", "CREATE", "ALTER", "DROP", "TRUNCATE TABLE",
                                 "SHOW", "DESCRIBE", "EXPLAIN", "USE", "SET", "CALL", "BEGIN", "START TRANSACTION", "COMMIT", "ROLLBACK", "RENAME TABLE",
                                 "ANALYZE TABLE", "OPTIMIZE TABLE", "GRANT", "REVOKE", "LOCK TABLES", "UNLOCK TABLES", "DELIMITER", "LOAD DATA", "PREPARE",
                                 "EXECUTE", "DEALLOCATE PREPARE", "KILL", "FLUSH"]
    private static let objects = ["TABLE", "VIEW", "INDEX", "DATABASE", "PROCEDURE", "FUNCTION", "TRIGGER", "EVENT", "USER"]
    private static let value = ["NULL", "NOT", "TRUE", "FALSE", "CASE", "WHEN", "THEN", "ELSE", "END", "EXISTS", "INTERVAL", "SELECT", "DISTINCT",
                                "DEFAULT", "BINARY", "CURRENT_TIMESTAMP", "CURRENT_DATE", "CURRENT_USER"]
    private static let conditions = ["AND", "OR", "XOR", "IN", "NOT IN", "LIKE", "NOT LIKE", "BETWEEN", "IS", "IS NULL", "IS NOT NULL", "REGEXP", "DIV", "MOD"]
    private static let tail = ["GROUP BY", "HAVING", "ORDER BY", "LIMIT", "UNION", "UNION ALL", "FOR UPDATE", "LOCK IN SHARE MODE", "INTO OUTFILE", "WINDOW"]
    private static let tableWords = ["JOIN", "LEFT JOIN", "RIGHT JOIN", "INNER JOIN", "CROSS JOIN", "NATURAL JOIN", "STRAIGHT_JOIN", "LEFT OUTER JOIN",
                                     "RIGHT OUTER JOIN", "ON", "USING", "AS", "WHERE", "USE INDEX", "FORCE INDEX", "IGNORE INDEX", "PARTITION", "LATERAL"]

    /// These words leave one thing to say, so no names are offered.
    static func onlyKeywords(after word: String, first: Bool) -> Bool {
        switch word {
        case "ORDER", "GROUP", "LEFT", "RIGHT", "INNER", "CROSS", "IS", "UNION", "CREATE", "DROP", "SHOW": return true
        case "INSERT", "DELETE", "REPLACE", "ALTER": return first
        default: return false
        }
    }

    static func after(_ word: String, clause: SQLClause? = nil, kind: SQLParsedStatement.Kind? = nil) -> [String] {
        switch word {
        case "ORDER", "GROUP": return ["BY"]
        case "LEFT", "RIGHT": return ["JOIN", "OUTER JOIN"]
        case "INNER", "CROSS", "OUTER", "NATURAL": return ["JOIN"]
        case "IS": return ["NULL", "NOT NULL", "TRUE", "FALSE", "UNKNOWN"]
        case "NOT": return ["IN", "LIKE", "BETWEEN", "EXISTS", "NULL", "REGEXP"]
        case "INSERT", "REPLACE": return ["INTO", "IGNORE INTO", "LOW_PRIORITY", "DELAYED"]
        case "DELETE": return ["FROM", "LOW_PRIORITY", "QUICK", "IGNORE"]
        case "UNION": return ["ALL", "DISTINCT", "SELECT"]
        case "CREATE": return objects + ["UNIQUE INDEX", "FULLTEXT INDEX", "TEMPORARY TABLE", "OR REPLACE", "ROLE", "DEFINER"]
        case "ALTER": return objects + ["SCHEMA"]
        case "DROP": return objects + ["TEMPORARY TABLE", "ROLE"]
        case "SHOW": return ["TABLES", "FULL TABLES", "DATABASES", "COLUMNS FROM", "FULL COLUMNS FROM", "INDEX FROM", "CREATE TABLE", "CREATE VIEW", "CREATE PROCEDURE",
                             "CREATE FUNCTION", "CREATE TRIGGER", "PROCESSLIST", "FULL PROCESSLIST", "VARIABLES", "GLOBAL VARIABLES", "STATUS", "GLOBAL STATUS",
                             "GRANTS", "ENGINE", "ENGINES", "WARNINGS", "ERRORS", "TABLE STATUS", "TRIGGERS", "EVENTS", "PROCEDURE STATUS", "FUNCTION STATUS",
                             "CHARACTER SET", "COLLATION", "PLUGINS", "PRIVILEGES", "BINARY LOGS", "MASTER STATUS", "SLAVE STATUS", "REPLICA STATUS"]
        default: break
        }
        switch kind {
        case .select:
            switch clause {
            case .selectList: return ["DISTINCT", "ALL", "FROM", "AS", "OVER", "PARTITION BY", "ORDER BY", "SQL_NO_CACHE", "STRAIGHT_JOIN"] + value + conditions
            case .from: return tableWords + tail
            case .on, .whereClause, .having: return value + conditions + tail + ["JOIN", "LEFT JOIN", "RIGHT JOIN", "INNER JOIN", "CROSS JOIN", "WHERE"]
            case .groupBy: return tail + ["WITH ROLLUP", "ASC", "DESC"] + value
            case .orderBy: return ["ASC", "DESC", "LIMIT", "FOR UPDATE", "LOCK IN SHARE MODE", "UNION"] + value
            case .limit: return ["OFFSET", "FOR UPDATE", "LOCK IN SHARE MODE", "UNION", "INTO OUTFILE"]
            default: break
            }
        case .insert, .replace:
            switch clause {
            case .values: return ["ON DUPLICATE KEY UPDATE", "AS", "VALUES", "ROW"] + value
            case .set: return ["ON DUPLICATE KEY UPDATE"] + value
            case .selectList, .from, .whereClause: break
            default: return ["VALUES", "VALUE", "SET", "SELECT", "PARTITION", "ON DUPLICATE KEY UPDATE", "RETURNING"]
            }
        case .update:
            switch clause {
            case .set: return ["WHERE", "ORDER BY", "LIMIT"] + value + conditions
            case .whereClause: return ["ORDER BY", "LIMIT"] + value + conditions
            case .orderBy, .limit: return ["ASC", "DESC", "LIMIT"]
            default: return tableWords + ["SET"]
            }
        case .delete:
            switch clause {
            case .whereClause: return ["ORDER BY", "LIMIT", "RETURNING"] + value + conditions
            case .orderBy, .limit: return ["ASC", "DESC", "LIMIT", "RETURNING"]
            default: return tableWords + ["ORDER BY", "LIMIT", "RETURNING"]
            }
        default:
            break
        }
        return SQLCompletion.keywords
    }

    static let setStart = ["NAMES", "SESSION", "GLOBAL", "PERSIST", "CHARACTER SET", "PASSWORD", "TRANSACTION", "ROLE", "AUTOCOMMIT"]

    static let engines = ["InnoDB", "MyISAM", "MEMORY", "CSV", "ARCHIVE", "Aria", "BLACKHOLE", "ROCKSDB"]
    static let charsets = ["utf8mb4", "utf8mb3", "latin1", "ascii", "binary", "utf16", "utf32", "ucs2", "cp1251", "gbk", "sjis", "big5"]
    static let collations = ["utf8mb4_general_ci", "utf8mb4_unicode_ci", "utf8mb4_bin", "utf8mb4_0900_ai_ci", "utf8mb4_0900_as_cs", "utf8mb4_uca1400_ai_ci",
                             "utf8mb3_general_ci", "latin1_swedish_ci", "latin1_general_ci", "ascii_general_ci", "binary"]

    /// The variables people set and read most: the schema cache holds none, and nothing goes to the server while typing.
    static let systemVariables = [
        "autocommit", "sql_mode", "time_zone", "foreign_key_checks", "unique_checks", "character_set_client", "character_set_connection",
        "character_set_results", "character_set_server", "collation_connection", "collation_server", "max_connections", "max_allowed_packet",
        "wait_timeout", "interactive_timeout", "lock_wait_timeout", "innodb_lock_wait_timeout", "innodb_buffer_pool_size", "sql_safe_updates",
        "sql_select_limit", "sql_log_bin", "tx_isolation", "transaction_isolation", "transaction_read_only", "group_concat_max_len",
        "long_query_time", "slow_query_log", "general_log", "log_bin", "read_only", "super_read_only", "server_id", "hostname", "version",
        "version_comment", "datadir", "tmpdir", "port", "socket", "lower_case_table_names", "default_storage_engine", "max_execution_time",
        "max_statement_time", "net_read_timeout", "net_write_timeout", "tmp_table_size", "max_heap_table_size", "sort_buffer_size",
        "join_buffer_size", "read_buffer_size", "thread_cache_size", "table_open_cache", "event_scheduler", "explicit_defaults_for_timestamp",
        "last_insert_id", "identity", "warning_count", "error_count", "timestamp", "pseudo_thread_id", "profiling", "optimizer_switch",
    ]
}
