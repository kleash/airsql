import Darwin
import Foundation

/// A .sql or .sql.gz file read statement by statement (Run SQL File, the restore's check): in pieces of a few MB,
/// split as the mysql client splits (`SQLSplitter`, DELIMITER included), each statement with the line it starts on.
/// A statement cut by a piece's end, and the delimiter in force there, carry over to the next piece.
public enum SQLScript {
    /// Opens `url` (gzip-compressed or not: its first bytes say) for reading.
    public static func open(_ url: URL, cancellation: Cancellation) throws -> (inflow: Runner.Inflow, fd: Int32, size: Int64) {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw AirSQLError(.other, "Can't open \(url.lastPathComponent): \(String(cString: strerror(errno)))") }
        var info = stat()
        fstat(fd, &info)
        var magic = [UInt8](repeating: 0, count: 2)
        let gzip = pread(fd, &magic, 2, 0) == 2 && magic == [0x1F, 0x8B]
        do {
            return (try Runner.Inflow(file: fd, through: gzip ? ["/usr/bin/gzip", "-dc"] : nil, cancellation: cancellation), fd,
                    Int64(info.st_size))
        } catch {
            close(fd)
            throw error
        }
    }

    /// Hands each statement of `inflow` to `each` with its line, in order, the next only once `each` has returned.
    public static func statements(from inflow: Runner.Inflow, noBackslashEscapes: Bool = false, pieceSize: Int = 4 << 20,
                                  each: (String, Int) async throws -> Void) async throws {
        var carry = Data(), delimiter = ";", line = 1
        while true {
            let piece = await withCheckedContinuation { continuation in
                Thread.detachNewThread { continuation.resume(returning: inflow.next(pieceSize)) }
            }
            let atEnd = piece == nil
            var bytes = carry
            if let piece { bytes.append(piece) }
            let cut = atEnd ? bytes.count : utf8Boundary(bytes)
            carry = bytes.subdata(in: cut..<bytes.count)
            let prefix = delimiter == ";" ? "" : "DELIMITER \(delimiter)\n"
            let text = prefix + String(decoding: bytes.prefix(cut), as: UTF8.self)
            let utf16 = Array(text.utf16)
            // Statements whose delimiter was read; what follows the last of them (a statement going on in the next
            // piece, a comment cut in two) is read again with the next piece, unless this is the end.
            let statements = SQLSplitter.statements(in: text, noBackslashEscapes: noBackslashEscapes)
                .filter { atEnd || $0.end > $0.range.upperBound }
            let rest = atEnd ? utf16.count : statements.last?.end ?? prefix.utf16.count
            // Lines: counted from the piece's start (the DELIMITER line put in front isn't the file's).
            var position = 0, at = line - (prefix.isEmpty ? 0 : 1)
            func advance(to offset: Int) {
                while position < offset {
                    if utf16[position] == 0x0A { at += 1 }
                    position += 1
                }
            }
            var gapStart = 0
            for statement in statements {
                delimiter = lastDelimiter(in: utf16[gapStart..<statement.range.lowerBound]) ?? delimiter
                advance(to: statement.range.lowerBound)
                try await each(statement.sql, at)
                gapStart = statement.end
            }
            advance(to: rest)
            line = at
            if atEnd { return }
            carry = Data(String(decoding: utf16[rest...], as: UTF16.self).utf8) + carry
        }
    }

    /// The delimiter the last DELIMITER line in a gap between statements sets, if one does.
    static func lastDelimiter(in gap: ArraySlice<UInt16>) -> String? {
        var found: String?
        for line in String(decoding: gap, as: UTF16.self).split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if words.count >= 2, words[0].uppercased() == "DELIMITER" { found = String(words[1]) }
        }
        return found
    }

    /// Where `bytes` can be cut without splitting a UTF-8 character: before a lead byte whose sequence isn't complete.
    static func utf8Boundary(_ bytes: Data) -> Int {
        var index = bytes.count
        for back in 1...min(3, bytes.count) where bytes.count >= back {
            let byte = bytes[bytes.startIndex + bytes.count - back]
            if byte & 0xC0 == 0x80 { continue }  // a continuation byte: look further back
            let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            if length > back { index = bytes.count - back }
            break
        }
        return index
    }

    /// Run SQL File without client tools (scope: run a .sql file inside the app): each statement of `url` through
    /// `session` in `database`, stopping at the first error unless `continueOnError` (then counted, the last kept).
    public static func run(_ url: URL, in database: String, on session: DBConnection, continueOnError: Bool,
                           cancellation: Cancellation, progress: @escaping (ToolProgress) -> Void) async throws -> ToolOutcome {
        let started = Date()
        let (inflow, fd, size) = try open(url, cancellation: cancellation)
        defer {
            _ = inflow.finish()
            close(fd)
        }
        if !database.isEmpty { _ = try await session.query("USE " + SQLQuote.identifier(database)) }
        var state = ToolProgress(total: size)
        try await statements(from: inflow, noBackslashEscapes: session.noBackslashEscapes) { sql, line in
            if cancellation.isCancelled { throw AirSQLError.cancelled }
            do {
                _ = try await session.query(sql, rowCap: 1)
            } catch let error as AirSQLError where error.kind != .disconnected && error.kind != .cancelled {
                let said = "Line \(line): \(error.message)" + (error.details.isEmpty ? "" : " (\(error.details))")
                guard continueOnError else { throw AirSQLError(error.kind, said, details: String(sql.prefix(300))) }
                state.errors += 1
                state.lastError = said
            }
            state.bytes = inflow.fed
            progress(state)
        }
        if cancellation.isCancelled { throw AirSQLError.cancelled }
        state.bytes = inflow.fed
        progress(state)
        return ToolOutcome(bytes: state.bytes, duration: Date().timeIntervalSince(started), errors: state.errors,
                           lastError: state.lastError)
    }
}

extension DumpScan {
    /// Reads the whole of `url` (.sql or .sql.gz) for the statements a restore must know about, off the main thread;
    /// `progress` gets the bytes of the file read and its size.
    public static func scan(_ url: URL, cancellation: Cancellation, progress: @escaping (Int64, Int64) -> Void) async throws -> DumpScan {
        let (inflow, fd, size) = try SQLScript.open(url, cancellation: cancellation)
        defer {
            _ = inflow.finish()
            close(fd)
        }
        var scan = DumpScan()
        try await SQLScript.statements(from: inflow) { sql, line in
            if cancellation.isCancelled { throw AirSQLError.cancelled }
            scan.add(words: words(of: sql), line: line)
            progress(inflow.fed, size)
        }
        if cancellation.isCancelled { throw AirSQLError.cancelled }
        return scan
    }

    /// A statement's first significant words as `add(words:line:)` takes them: no comments, executable comments' marks
    /// left out, quoted names without their quotes (only the start is read: what matters is there).
    static func words(of sql: String) -> [String] {
        let start = String(sql.prefix(512))
        let text = Array(start.utf16)
        return SQLLexer.tokens(start).compactMap { token -> String? in
            let word = String(decoding: text[token.range], as: UTF16.self)
            switch token.kind {
            case .comment, .hint, .codeStart, .codeEnd: return nil
            case .quotedName: return String(word.dropFirst().dropLast()).replacingOccurrences(of: "``", with: "`")
            default: return word
            }
        }
    }
}
