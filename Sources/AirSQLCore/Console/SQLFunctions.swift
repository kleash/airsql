/// The built-in functions completion and the helpers panel offer (plan §2.6): the common ones of each kind, with how
/// they are called and, for those only one server or later versions have, which.
public struct SQLFunction: Equatable {
    public enum Group: String, CaseIterable {
        case aggregate = "Aggregate", string = "Text", number = "Numbers", date = "Dates and times", json = "JSON",
             flow = "Conditions", window = "Window", other = "Other"
    }

    public var name: String
    /// How it is called: "CONCAT(text, …)".
    public var call: String
    public var group: Group
    /// Only on this server; nil: both.
    public var only: SchemaServer.Flavour?
    /// The first version that has it ([8, 0] for MySQL 8.0), on `only` (or MySQL's when both have it from the start).
    public var since: [Int]?

    /// Whether `server` has it (every function, when the server isn't known yet).
    public func available(on server: SchemaServer?) -> Bool {
        guard let server else { return true }
        if let only, only != server.flavour { return false }
        guard let since, only != nil || server.flavour == .mysql else { return true }
        return server.atLeast(since[0], since.count > 1 ? since[1] : 0, since.count > 2 ? since[2] : 0)
    }

    init(_ call: String, _ group: Group, only: SchemaServer.Flavour? = nil, since: [Int]? = nil) {
        self.call = call
        name = String(call.prefix { $0 != "(" })
        self.group = group
        self.only = only
        self.since = since
    }

    public static let all: [SQLFunction] = [
        .init("COUNT(expr)", .aggregate), .init("SUM(expr)", .aggregate), .init("AVG(expr)", .aggregate),
        .init("MIN(expr)", .aggregate), .init("MAX(expr)", .aggregate), .init("GROUP_CONCAT(expr ORDER BY … SEPARATOR ', ')", .aggregate),
        .init("STDDEV(expr)", .aggregate), .init("VARIANCE(expr)", .aggregate), .init("BIT_AND(expr)", .aggregate),
        .init("BIT_OR(expr)", .aggregate), .init("JSON_ARRAYAGG(expr)", .aggregate), .init("JSON_OBJECTAGG(key, value)", .aggregate),
        .init("ANY_VALUE(expr)", .aggregate, only: .mysql),
        .init("CONCAT(text, …)", .string), .init("CONCAT_WS(separator, text, …)", .string), .init("LENGTH(text)", .string),
        .init("CHAR_LENGTH(text)", .string), .init("LOWER(text)", .string), .init("UPPER(text)", .string),
        .init("SUBSTRING(text, start, length)", .string), .init("SUBSTRING_INDEX(text, delimiter, count)", .string),
        .init("LEFT(text, length)", .string), .init("RIGHT(text, length)", .string), .init("TRIM(text)", .string),
        .init("LTRIM(text)", .string), .init("RTRIM(text)", .string), .init("REPLACE(text, from, to)", .string),
        .init("LOCATE(find, text)", .string), .init("INSTR(text, find)", .string), .init("LPAD(text, length, pad)", .string),
        .init("RPAD(text, length, pad)", .string), .init("REVERSE(text)", .string), .init("REPEAT(text, count)", .string),
        .init("FORMAT(number, decimals)", .string), .init("HEX(value)", .string), .init("UNHEX(text)", .string),
        .init("MD5(text)", .string), .init("SHA2(text, bits)", .string), .init("REGEXP_REPLACE(text, pattern, replacement)", .string),
        .init("REGEXP_SUBSTR(text, pattern)", .string), .init("REGEXP_LIKE(text, pattern)", .string, only: .mysql, since: [8, 0]),
        .init("SFORMAT(format, value, …)", .string, only: .mariadb, since: [10, 7]),
        .init("NATURAL_SORT_KEY(text)", .string, only: .mariadb, since: [10, 7]),
        .init("ABS(number)", .number), .init("ROUND(number, decimals)", .number), .init("TRUNCATE(number, decimals)", .number),
        .init("CEIL(number)", .number), .init("FLOOR(number)", .number), .init("MOD(number, divisor)", .number),
        .init("POW(number, power)", .number), .init("SQRT(number)", .number), .init("RAND()", .number), .init("SIGN(number)", .number),
        .init("GREATEST(value, …)", .number), .init("LEAST(value, …)", .number), .init("CONV(number, from, to)", .number),
        .init("NOW()", .date), .init("CURDATE()", .date), .init("CURTIME()", .date), .init("UTC_TIMESTAMP()", .date),
        .init("DATE(datetime)", .date), .init("TIME(datetime)", .date), .init("YEAR(date)", .date), .init("MONTH(date)", .date),
        .init("DAY(date)", .date), .init("HOUR(time)", .date), .init("MINUTE(time)", .date), .init("DAYOFWEEK(date)", .date),
        .init("DATE_ADD(date, INTERVAL n unit)", .date), .init("DATE_SUB(date, INTERVAL n unit)", .date),
        .init("DATEDIFF(end, start)", .date), .init("TIMESTAMPDIFF(unit, start, end)", .date),
        .init("DATE_FORMAT(date, format)", .date), .init("STR_TO_DATE(text, format)", .date), .init("UNIX_TIMESTAMP(datetime)", .date),
        .init("FROM_UNIXTIME(seconds)", .date), .init("LAST_DAY(date)", .date), .init("CONVERT_TZ(datetime, from, to)", .date),
        .init("JSON_EXTRACT(json, path)", .json), .init("JSON_UNQUOTE(json)", .json), .init("JSON_VALUE(json, path)", .json),
        .init("JSON_OBJECT(key, value, …)", .json), .init("JSON_ARRAY(value, …)", .json), .init("JSON_CONTAINS(json, value)", .json),
        .init("JSON_SET(json, path, value)", .json), .init("JSON_REMOVE(json, path)", .json), .init("JSON_KEYS(json)", .json),
        .init("JSON_LENGTH(json)", .json), .init("JSON_VALID(text)", .json),
        .init("JSON_TABLE(json, path COLUMNS (…))", .json, only: .mysql, since: [8, 0]),
        .init("JSON_DETAILED(json)", .json, only: .mariadb),
        .init("IF(condition, then, else)", .flow), .init("IFNULL(value, fallback)", .flow), .init("NULLIF(value, other)", .flow),
        .init("COALESCE(value, …)", .flow), .init("CAST(value AS type)", .flow), .init("CONVERT(value, type)", .flow),
        .init("ROW_NUMBER() OVER (…)", .window, since: [8, 0]), .init("RANK() OVER (…)", .window, since: [8, 0]),
        .init("DENSE_RANK() OVER (…)", .window, since: [8, 0]), .init("LAG(expr) OVER (…)", .window, since: [8, 0]),
        .init("LEAD(expr) OVER (…)", .window, since: [8, 0]), .init("FIRST_VALUE(expr) OVER (…)", .window, since: [8, 0]),
        .init("NTILE(n) OVER (…)", .window, since: [8, 0]),
        .init("DATABASE()", .other), .init("USER()", .other), .init("CURRENT_USER()", .other), .init("VERSION()", .other),
        .init("CONNECTION_ID()", .other), .init("LAST_INSERT_ID()", .other), .init("ROW_COUNT()", .other), .init("UUID()", .other),
        .init("UUID_TO_BIN(uuid)", .other, only: .mysql, since: [8, 0]), .init("BIN_TO_UUID(bytes)", .other, only: .mysql, since: [8, 0]),
    ]
}
