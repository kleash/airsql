import Darwin
import Foundation

/// The SQL log: every statement AirSQL sends to a server, written by `DBConnection` just before the statement goes out
/// (so nothing can bypass it), one entry per statement:
///
///     2026-11-03 14:03:12.345 [Shop production main:12] SELECT * FROM orders
///
/// with the connection's name, the session (main, data, schema, agent, tools, cancel) and the statement's number in it
/// (the number in the statement's /* airsql:main:12 */ tag). Also logged: connects (server, thread, TLS), disconnects,
/// cancels, reconnects, and failed statements' error numbers (not their text: a syntax error quotes the statement,
/// secrets included). Credentials are masked as MySQL masks its own logs (`mask`); a connection's startup SQL is
/// logged only as "startup SQL (3 statements)"; passwords used to log in never reach SQL at all. The file is
/// ~/Library/Logs/AirSQL/SQL.log (a throwaway AirSQL's is in its AIRSQL_SUPPORT_DIR), mode 0600; at 10 MB it becomes
/// SQL.1.log, replacing the one before, and a new file starts.
public final class SQLLog {
    public static let shared = SQLLog(fileURL: defaultURL)

    public static var defaultURL: URL {
        if Env.isThrowaway() { return Store.directory.appendingPathComponent("SQL.log") }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/AirSQL/SQL.log")
    }

    public let fileURL: URL
    /// The file before the current one.
    public var previousFileURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("SQL.1.log") }
    /// At this size the file becomes the previous one.
    let sizeLimit: Int

    public init(fileURL: URL, sizeLimit: Int = 10 << 20) {
        self.fileURL = fileURL
        self.sizeLimit = sizeLimit
    }

    /// A statement about to be sent, masked. `noBackslashEscapes`: the session's sql_mode, which decides where its
    /// string literals end.
    func statement(_ sql: String, context: String, noBackslashEscapes: Bool) {
        // A NUL inside a literal (sent as is under NO_BACKSLASH_ESCAPES) would make the file binary to grep and editors.
        var text = Self.mask(sql, noBackslashEscapes: noBackslashEscapes).replacingOccurrences(of: "\u{0}", with: "\\0")
        // An import's 50,000-row INSERT: its start is enough.
        if text.utf8.count > 65_536 {
            let total = text.utf8.count
            text = String(decoding: text.utf8.prefix(60_000), as: UTF8.self) + " … (\(total - 60_000) more bytes)"
        }
        write(text, context: context)
    }

    /// A line of AirSQL's own about a session ("connected: …", "error 1064").
    public func note(_ text: String, context: String) {
        write("-- " + text, context: context)
    }

    // MARK: Masking

    /// `sql` with the credentials in it replaced by <secret>, as MySQL rewrites statements for its general log, and a
    /// little more: the literal after IDENTIFIED … BY / USING / REPLACE; after a word ending in PASSWORD (PASSWORD 'x',
    /// MASTER_PASSWORD = 'x', SOURCE_PASSWORD = 'x', a password column = 'x'); after SET PASSWORD … =; every literal in
    /// PASSWORD(…), OLD_PASSWORD(…) and VALIDATE_PASSWORD_STRENGTH(…); the key (every argument after the first) of
    /// AES_ENCRYPT, AES_DECRYPT, DES_ENCRYPT, DES_DECRYPT, ENCODE, DECODE and ENCRYPT. Comments are skipped and
    /// executable comments (/*! … */) read as code.
    public static func mask(_ sql: String, noBackslashEscapes: Bool = false) -> String {
        let bytes = Array(sql.utf8)
        let tokens = scan(bytes, noBackslashEscapes: noBackslashEscapes)
        var secrets: [Range<Int>] = []
        var inAuth = false, setPassword = false, statementStart = 0
        var depth = 0
        var calls: [(passwordCall: Bool, depth: Int, argument: Int)] = []

        for (k, token) in tokens.enumerated() {
            let previous = k > 0 ? tokens[k - 1] : nil
            switch token.kind {
            case .word:
                let word = token.upper(bytes)
                if word == "IDENTIFIED" { inAuth = true }
                if k == statementStart + 1, word == "PASSWORD", tokens[statementStart].upper(bytes) == "SET" { setPassword = true }
            case .symbol(UInt8(ascii: "(")):
                depth += 1
                if let name = previous?.upper(bytes), previous?.kind == .word {
                    if passwordFunctions.contains(name) { calls.append((true, depth, 0)) }
                    if keyFunctions.contains(name) { calls.append((false, depth, 0)) }
                }
            case .symbol(UInt8(ascii: ")")):
                if calls.last?.depth == depth { calls.removeLast() }
                depth = max(0, depth - 1)
            case .symbol(UInt8(ascii: ",")):
                if calls.last?.depth == depth { calls[calls.count - 1].argument += 1 }
            case .symbol(UInt8(ascii: ";")):
                inAuth = false
                setPassword = false
                calls = []
                depth = 0
                statementStart = k + 1
            case .literal, .number:
                let before = previous?.kind == .word ? previous!.upper(bytes) : nil
                let equalsAfter = previous?.kind == .symbol(UInt8(ascii: "=")) && k >= 2 && tokens[k - 2].kind == .word
                    ? tokens[k - 2].upper(bytes) : nil
                let secret = (token.kind == .literal && inAuth && ["BY", "USING", "REPLACE"].contains(before ?? ""))
                    || (token.kind == .literal && (before?.hasSuffix("PASSWORD") ?? false))
                    || (equalsAfter?.hasSuffix("PASSWORD") ?? false)
                    || (setPassword && previous?.kind == .symbol(UInt8(ascii: "=")))
                    || calls.contains { $0.passwordCall || $0.argument >= 1 }
                if secret { secrets.append(token.range) }
            default:
                break
            }
        }
        guard !secrets.isEmpty else { return sql }
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var from = 0
        for range in secrets {
            result += bytes[from..<range.lowerBound]
            result += Array("<secret>".utf8)
            from = range.upperBound
        }
        result += bytes[from...]
        return String(decoding: result, as: UTF8.self)
    }

    private static let passwordFunctions: Set = ["PASSWORD", "OLD_PASSWORD", "VALIDATE_PASSWORD_STRENGTH"]
    private static let keyFunctions: Set = ["AES_ENCRYPT", "AES_DECRYPT", "DES_ENCRYPT", "DES_DECRYPT", "ENCODE", "DECODE",
                                            "ENCRYPT"]

    private struct Token {
        enum Kind: Equatable { case word, number, literal, identifier, symbol(UInt8) }
        var kind: Kind
        var range: Range<Int>

        func upper(_ bytes: [UInt8]) -> String {
            String(decoding: bytes[range].map { (0x61...0x7A).contains($0) ? $0 - 0x20 : $0 }, as: UTF8.self)
        }
    }

    /// Words, numbers, string literals (with an X, B, N or _charset prefix), `names` and single symbols; whitespace and
    /// comments left out. Just enough of MySQL's lexer to find the literals.
    private static func scan(_ b: [UInt8], noBackslashEscapes: Bool) -> [Token] {
        var tokens: [Token] = []
        var i = 0
        func isWord(_ byte: UInt8) -> Bool {
            byte >= 0x80 || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "$") || (0x30...0x39).contains(byte)
                || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
        }
        /// The index after the quoted text that starts at `start` (on its opening quote).
        func endOfQuoted(_ start: Int) -> Int {
            let quote = b[start]
            var j = start + 1
            while j < b.count {
                if b[j] == UInt8(ascii: "\\") && quote != UInt8(ascii: "`") && !noBackslashEscapes {
                    j += 2
                } else if b[j] == quote {
                    if j + 1 < b.count && b[j + 1] == quote { j += 2 } else { return j + 1 }
                } else {
                    j += 1
                }
            }
            return b.count
        }
        while i < b.count {
            let c = b[i]
            let next = i + 1 < b.count ? b[i + 1] : 0
            if c == 0x20 || (0x09...0x0D).contains(c) {
                i += 1
            } else if c == UInt8(ascii: "#") || (c == UInt8(ascii: "-") && next == UInt8(ascii: "-")
                                                    && (i + 2 >= b.count || b[i + 2] <= 0x20)) {
                while i < b.count && b[i] != 0x0A { i += 1 }
            } else if c == UInt8(ascii: "/") && next == UInt8(ascii: "*") {
                // /*! … */ and /*M! … */ hold code that the server runs: read on inside (their */ is skipped below).
                var j = i + 2
                if j < b.count && b[j] == UInt8(ascii: "M") && j + 1 < b.count && b[j + 1] == UInt8(ascii: "!") { j += 1 }
                if j < b.count && b[j] == UInt8(ascii: "!") {
                    j += 1
                    while j < b.count && (0x30...0x39).contains(b[j]) { j += 1 }
                    i = j
                } else {
                    while j + 1 < b.count && !(b[j] == UInt8(ascii: "*") && b[j + 1] == UInt8(ascii: "/")) { j += 1 }
                    i = min(b.count, j + 2)
                }
            } else if c == UInt8(ascii: "*") && next == UInt8(ascii: "/") {
                i += 2
            } else if c == UInt8(ascii: "'") || c == UInt8(ascii: "\"") {
                let end = endOfQuoted(i)
                tokens.append(Token(kind: .literal, range: i..<end))
                i = end
            } else if c == UInt8(ascii: "`") {
                let end = endOfQuoted(i)
                tokens.append(Token(kind: .identifier, range: i..<end))
                i = end
            } else if isWord(c) {
                var j = i
                while j < b.count && isWord(b[j]) { j += 1 }
                // X'…', B'…', N'…' and _utf8mb4'…' are one literal with their prefix.
                if j < b.count && b[j] == UInt8(ascii: "'")
                    && (j - i == 1 && "xXbBnN".utf8.contains(c) || c == UInt8(ascii: "_")) {
                    let end = endOfQuoted(j)
                    tokens.append(Token(kind: .literal, range: i..<end))
                    i = end
                } else {
                    tokens.append(Token(kind: (0x30...0x39).contains(c) ? .number : .word, range: i..<j))
                    i = j
                }
            } else {
                tokens.append(Token(kind: .symbol(c), range: i..<i + 1))
                i += 1
            }
        }
        return tokens
    }

    // MARK: The file

    private let lock = NSLock()
    private var file: Int32 = -1
    private var size = 0
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    func write(_ text: String, context: String) {
        let line = Self.formatter.string(from: Date()) + " [\(context)] " + text + "\n"
        lock.lock()
        defer { lock.unlock() }
        // A file removed meanwhile (the user deleted it) is made again.
        var info = stat()
        if file >= 0, fstat(file, &info) != 0 || info.st_nlink == 0 {
            close(file)
            file = -1
        }
        if file < 0 {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            file = open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
            guard file >= 0 else { return }
            fchmod(file, 0o600)  // a file made by something else keeps no wider mode
            size = fstat(file, &info) == 0 ? Int(info.st_size) : 0
        }
        let written = line.utf8CString.withUnsafeBufferPointer { Darwin.write(file, $0.baseAddress, $0.count - 1) }
        size += max(0, written)
        if size >= sizeLimit {
            close(file)
            file = -1
            rename(fileURL.path, previousFileURL.path)
        }
    }
}
