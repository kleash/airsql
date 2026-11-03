import CMariaDB

/// The one way AirSQL writes names and values into SQL (plan §2.2, R18): every generator builds its statements with
/// these, never by pasting text between quotes.
public enum SQLQuote {
    /// A name (database, table, column, index, user, …) in backticks, each backtick in it written twice:
    /// my`table → `my``table`. Backticks quote names in every sql_mode (ANSI_QUOTES only adds double quotes).
    public static func identifier(_ name: String) -> String {
        "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
    }

    /// A qualified name: `shop`.`orders`, `shop`.`orders`.`id`.
    public static func identifier(_ first: String, _ rest: String...) -> String {
        ([first] + rest).map(identifier).joined(separator: ".")
    }

    /// A name read back from SQL: `my``table` → my`table; text that isn't in backticks as it is.
    public static func unquoted(_ name: String) -> String {
        guard name.count >= 2, name.hasPrefix("`"), name.hasSuffix("`") else { return name }
        return String(name.dropFirst().dropLast()).replacingOccurrences(of: "``", with: "`")
    }

    /// Text as a string literal in single quotes. With the server's usual sql_mode it is escaped as
    /// mysql_real_escape_string escapes it on AirSQL's utf8mb4 connections (\0 \n \r \\ \' \" \Z); when the session
    /// reports NO_BACKSLASH_ESCAPES (`DBConnection.noBackslashEscapes`) a backslash is an ordinary character there, so
    /// only ' is written twice. Single quotes are strings in every sql_mode, ANSI_QUOTES included.
    public static func string(_ text: String, noBackslashEscapes: Bool = false) -> String {
        if noBackslashEscapes { return "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }
        _ = DBConnection.library  // mysql_escape_string reads the library's default character set
        let bytes = Array(text.utf8)
        // mysql_real_escape_string's rules without a connection: Connector/C's charset-free twin. A UTF-8 sequence never
        // holds one of the escaped ASCII bytes, so escaping byte by byte gives what a utf8mb4 connection would.
        var escaped = [CChar](repeating: 0, count: bytes.count * 2 + 1)
        let length = bytes.withUnsafeBufferPointer { from in
            from.withMemoryRebound(to: CChar.self) { mysql_escape_string(&escaped, $0.baseAddress, UInt($0.count)) }
        }
        return "'" + String(decoding: escaped.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self) + "'"
    }

    /// Bytes as a hexadecimal literal, X'00FF' (X'' for none): binary values, whatever the sql_mode or character set.
    public static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        let digits = Array("0123456789ABCDEF".utf8)
        var text = Array("X'".utf8)
        for byte in bytes {
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0F)])
        }
        text.append(UInt8(ascii: "'"))
        return String(decoding: text, as: UTF8.self)
    }

    /// A BIT value as a bit-value literal: 5 → b'101', 0 → b'0'.
    public static func bits(_ value: UInt64) -> String {
        "b'" + String(value, radix: 2) + "'"
    }
}
