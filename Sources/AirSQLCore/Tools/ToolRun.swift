import Darwin
import Foundation

/// How far a dump or restore has got, for its sheet's progress bar.
public struct ToolProgress: Equatable, Sendable {
    /// Bytes of SQL written (dump) or bytes of the file read (restore).
    public var bytes: Int64 = 0
    /// What `bytes` is heading for: the file's size (restore), the tables' size on the server (dump, a guess).
    public var total: Int64?
    /// The table mysqldump is writing.
    public var table: String?
    /// Errors so far (restore going on past errors), and the latest.
    public var errors = 0
    public var lastError: String?

    public init(total: Int64? = nil) { self.total = total }
}

/// What a finished dump or restore did.
public struct ToolOutcome: Equatable, Sendable {
    public var bytes: Int64
    public var duration: TimeInterval
    /// Errors the restore went on past (--force), and the last of them.
    public var errors: Int
    public var lastError: String?
}

/// Runs the client tools for Export, Restore and Terminal (plan §2.9): the login in a private option file, removed as
/// soon as the tool has read it (once it has connected), progress by bytes, Cancel.
public enum ToolRun {
    /// Dumps with `command` into `url` (through /usr/bin/gzip when asked). The dump goes into a part file next to it,
    /// which takes `url`'s place once mysqldump has finished well, so a failed or cancelled dump leaves no half file.
    public static func dump(_ command: ToolCommand, _ request: DumpRequest, to url: URL, estimate: Int64?,
                            cancellation: Cancellation, progress: @escaping (ToolProgress) -> Void) async throws -> ToolOutcome {
        let started = Date()
        let optionFile = try OptionFile.write(user: command.options.user, password: command.options.password)
        let remove = Once { unlink(optionFile.path) }
        defer { remove.run() }
        let part = try PartFile(url)
        var state = ToolProgress(total: estimate)
        var tail = Data()
        let argv = command.dump(request, optionFile: optionFile.path)
        let piped = await Runner.output(of: argv, to: part.fd, through: request.gzip ? ["/usr/bin/gzip", "-c"] : nil,
                                        cancellation: cancellation, begun: { remove.run() }, chunk: { data in
            state.bytes += Int64(data.count)
            // mysqldump's comments name each table as it starts on it ("-- Dumping data for table `orders`").
            let window = tail + data
            if let name = lastTable(in: window) { state.table = name }
            tail = window.suffix(160)
            progress(state)
        })
        guard !cancellation.isCancelled, piped.tool.status == 0, piped.filter?.status ?? 0 == 0, piped.ioError == nil else {
            part.discard()
            if cancellation.isCancelled { throw AirSQLError.cancelled }
            if let error = piped.ioError {
                throw AirSQLError(.other, "Can't write the dump: \(String(cString: strerror(error)))")
            }
            throw failure(command.tool.name, piped.tool.status == 0 ? piped.filter ?? piped.tool : piped.tool)
        }
        try part.keep()
        return ToolOutcome(bytes: piped.bytes, duration: Date().timeIntervalSince(started), errors: 0, lastError: nil)
    }

    /// AirSQL's own export of `request` into `url` (through /usr/bin/gzip when asked) through a session of its own, with
    /// the same part file as `dump`. `progress` gets the export's rows and the bytes of SQL written.
    public static func export(_ request: DumpRequest, options: ConnectOptions, to url: URL, cancellation: Cancellation,
                              progress: @escaping (SQLExport.Progress, Int64) -> Void) async throws -> ToolOutcome {
        let started = Date()
        let session = DBConnection(options: options, role: .tools)
        let part = try PartFile(url)
        do {
            _ = try await session.connect()
            let writer = try Runner.Writer(file: part.fd, through: request.gzip ? ["/usr/bin/gzip", "-c"] : nil,
                                           cancellation: cancellation)
            do {
                try await SQLExport.run(request, from: session, into: SQLFileSink(writer), cancellation: cancellation) { done in
                    progress(done, writer.bytes)
                }
            } catch {
                _ = writer.finish()
                throw error
            }
            if let gzip = writer.finish(), gzip.status != 0 {
                throw AirSQLError(.other, "gzip stopped: " + gzip.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            await session.close()
            try part.keep()
            return ToolOutcome(bytes: writer.bytes, duration: Date().timeIntervalSince(started), errors: 0, lastError: nil)
        } catch {
            await session.close()
            part.discard()
            throw cancellation.isCancelled ? AirSQLError.cancelled : error
        }
    }

    /// A hidden file next to `url` that takes its place once complete (a failed or cancelled run leaves nothing).
    final class PartFile {
        let url: URL
        let part: URL
        let fd: Int32

        init(_ url: URL) throws {
            self.url = url
            part = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(6)).part")
            fd = open(part.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
            guard fd >= 0 else {
                throw AirSQLError(.other, "Can't write in \(url.deletingLastPathComponent().path): \(String(cString: strerror(errno)))")
            }
        }

        func discard() {
            close(fd)
            unlink(part.path)
        }

        func keep() throws {
            close(fd)
            guard rename(part.path, url.path) == 0 else {
                let reason = String(cString: strerror(errno))
                unlink(part.path)
                throw AirSQLError(.other, "Can't save \(url.lastPathComponent): \(reason)")
            }
        }
    }

    /// Runs the SQL in `url` (.sql, or gzip-compressed .sql.gz) with `command`'s client in `database`, stopping at the
    /// first error unless `continueOnError`. Progress is the share of the file read.
    public static func restore(_ command: ToolCommand, file url: URL, into database: String, continueOnError: Bool,
                               cancellation: Cancellation, progress: @escaping (ToolProgress) -> Void) async throws -> ToolOutcome {
        let started = Date()
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw AirSQLError(.other, "Can't open \(url.lastPathComponent): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var info = stat()
        fstat(fd, &info)
        let compressed = isGzip(fd)
        let optionFile = try OptionFile.write(user: command.options.user, password: command.options.password)
        let remove = Once { unlink(optionFile.path) }
        defer { remove.run() }
        let lock = NSLock()
        var state = ToolProgress(total: Int64(info.st_size))
        var pending = ""
        let argv = command.restore(into: database, continueOnError: continueOnError, optionFile: optionFile.path)
        let piped = await Runner.input(of: argv, from: fd, through: compressed ? ["/usr/bin/gzip", "-dc"] : nil,
                                       cancellation: cancellation, begun: { remove.run() }, errorOutput: { text in
            // "ERROR 1062 (23000) at line 52: Duplicate entry '7' for key 'PRIMARY'", one per error.
            let now = lock.locked { () -> ToolProgress in
                pending += text
                var lines = pending.components(separatedBy: "\n")
                pending = lines.removeLast()
                for line in lines where line.hasPrefix("ERROR") {
                    state.errors += 1
                    state.lastError = line
                }
                return state
            }
            progress(now)
        }, progress: { bytes in
            progress(lock.locked { () -> ToolProgress in
                state.bytes = bytes
                return state
            })
        })
        let final = lock.locked { state }
        if cancellation.isCancelled { throw AirSQLError.cancelled }
        if let error = piped.ioError { throw AirSQLError(.other, "Can't read \(url.lastPathComponent): \(String(cString: strerror(error)))") }
        if let filter = piped.filter, filter.status != 0, piped.tool.status == 0 {
            throw AirSQLError(.other, "\(url.lastPathComponent) isn't a complete gzip file.", details: filter.stderr)
        }
        // With --force the client goes on past errors and still ends with status 1: that is a finished restore.
        guard piped.tool.status == 0 || (continueOnError && final.errors > 0 && piped.tool.status == 1) else {
            throw failure(command.tool.name, piped.tool)
        }
        return ToolOutcome(bytes: piped.bytes, duration: Date().timeIntervalSince(started), errors: final.errors,
                           lastError: final.lastError)
    }

    /// Opens `command`'s client in Terminal: a script in the private folder that removes itself, removes the option file
    /// 10 seconds after it starts (the client reads it at once), and then becomes mysql. Whatever Terminal never ran is
    /// removed by the app after two minutes, or at the next launch.
    public static func openInTerminal(_ command: ToolCommand, database: String, name: String) async throws {
        let optionFile = try OptionFile.write(user: command.options.user, password: command.options.password)
        let argv = command.terminal(database: database, optionFile: optionFile.path)
        let script = "#!/bin/sh\nrm -f -- \"$0\"\n(trap '' HUP; sleep 10; rm -f -- \(ToolCommand.shellWord(optionFile.path))) &\nexec "
            + argv.map(ToolCommand.shellWord).joined(separator: " ") + "\n"
        let safe = String(name.map { "/:\n".contains($0) ? "-" : $0 }.prefix(60))
        let url = try OptionFile.create(Data(script.utf8), named: "\(safe) \(UUID().uuidString.prefix(6).lowercased()).command",
                                        mode: 0o700)
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
            unlink(optionFile.path)
            unlink(url.path)
        }
        let result = await Runner.run(["/usr/bin/open", "-a", "Terminal", url.path])
        guard result.status == 0 else {
            unlink(optionFile.path)
            unlink(url.path)
            throw AirSQLError(.other, "Terminal couldn't open the mysql command line.", details: result.stderr)
        }
    }

    /// The table named last in a stretch of mysqldump's output.
    static func lastTable(in data: Data) -> String? {
        var last: (at: Data.Index, name: String)?
        for marker in ["-- Table structure for table `", "-- Dumping data for table `"] {
            var from = data.startIndex
            while let range = data.range(of: Data(marker.utf8), in: from..<data.endIndex) {
                from = range.upperBound
                guard let end = data.range(of: Data("`\n".utf8), in: range.upperBound..<data.endIndex) else { break }
                if range.lowerBound > last?.at ?? -1 {
                    last = (range.lowerBound, String(decoding: data[range.upperBound..<end.lowerBound], as: UTF8.self))
                }
            }
        }
        return last?.name.replacingOccurrences(of: "``", with: "`")
    }

    /// The file starts with gzip's magic bytes (it is read from the start again afterwards).
    private static func isGzip(_ fd: Int32) -> Bool {
        var magic = [UInt8](repeating: 0, count: 2)
        let count = pread(fd, &magic, 2, 0)
        return count == 2 && magic == [0x1F, 0x8B]
    }

    /// A tool that ended badly, in its own words: its error output's last lines.
    private static func failure(_ name: String, _ result: CommandResult) -> AirSQLError {
        let lines = result.stderr.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.contains("[Warning]") }
        let said = lines.last(where: { $0.contains("ERROR") || $0.contains("error") }) ?? lines.last
        let message = result.status == 127 ? "Can't start \(name)." : "\(name) stopped: " + (said ?? "it ended with status \(result.status).")
        return AirSQLError(.other, message, details: lines.suffix(20).joined(separator: "\n"))
    }
}

/// Runs its action the first time `run` is called, from any thread.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() -> Void)?

    init(_ action: @escaping () -> Void) { self.action = action }

    func run() {
        let now = lock.locked { () -> (() -> Void)? in
            defer { action = nil }
            return action
        }
        now?()
    }
}
