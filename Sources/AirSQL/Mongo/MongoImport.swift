import AirSQLCore
import Foundation

/// What Import Documents… reads and writes (mongo-plan, Import): the Extended JSON documents of a file (JSON Lines,
/// documents one after another, or one array), read a document at a time and inserted in batches of at most 1,000
/// documents and 8 MB, so a file of any size takes little memory.
enum MongoImport {
    static let batchCount = 1000
    static let batchBytes = 8 << 20

    struct Report: Sendable {
        var inserted = 0
        /// The documents the server refused, and of those the ones whose _id the collection holds already.
        var refused = 0, duplicates = 0
        /// The lines that couldn't be read, skipped.
        var skipped = 0
        /// The first problems, each with its line or document number.
        var problems: [String] = []
        /// Why the import stopped before the end of the file.
        var stopped: String?
        var cancelled = false
        /// Every problem noted, beyond the first ten kept too.
        var noted = 0

        mutating func note(_ problem: String) {
            noted += 1
            if problems.count < 10 { problems.append(problem) }
        }
    }

    /// A file's documents one at a time, with where each is ("Line 4", "Document 4"). `skipBad`: JSON Lines read a line
    /// at a time, a line that can't be read noted in the report and skipped; else `ExtendedJSONReader`, which reads any
    /// layout and throws at a document it can't read.
    struct Source {
        private let handle: FileHandle
        private var reader: ExtendedJSONReader?
        private var lines: LineReader?
        private var count = 0

        init(_ url: URL, skipBad: Bool) throws {
            handle = try FileHandle(forReadingFrom: url)
            if skipBad { lines = LineReader(handle) } else { reader = ExtendedJSONReader(handle) }
        }

        /// How far into the file the reading is.
        var offset: UInt64 { (try? handle.offset()) ?? 0 }

        mutating func next(_ report: inout Report) throws -> (BSONDocument, String)? {
            if reader != nil {
                guard let document = try reader?.next() else { return nil }
                count += 1
                return (document, "Document \(count)")
            }
            while let (number, line) = try lines?.next() {
                let text = String(bytes: line, encoding: .utf8)?.trimmingCharacters(in: .whitespaces)
                if text?.isEmpty == true { continue }
                do {
                    guard let text else { throw BSONError("Line 1: the line isn't UTF-8 text") }
                    return (try BSONDocument(extendedJSON: text), "Line \(number)")
                } catch {
                    // The parser counts from the line it was given.
                    let message = MongoImport.message(error).replacingOccurrences(of: "Line 1", with: "Line \(number)",
                                                                                  options: .anchored)
                    report.skipped += 1
                    report.note(message)
                }
            }
            return nil
        }
    }

    /// Lines of a file, from a 64 KB buffer; a line past 64 MB is an error rather than memory.
    struct LineReader {
        private let handle: FileHandle
        private var buffer: [UInt8] = []
        private var start = 0
        private var ended = false
        private var number = 0

        init(_ handle: FileHandle) { self.handle = handle }

        mutating func next() throws -> (Int, ArraySlice<UInt8>)? {
            while true {
                if let end = buffer[start...].firstIndex(of: 0x0A) {
                    defer { start = end + 1 }
                    return line(buffer[start..<end])
                }
                if ended {
                    guard start < buffer.count else { return nil }
                    defer { start = buffer.count }
                    return line(buffer[start...])
                }
                buffer.removeSubrange(0..<start)
                start = 0
                guard buffer.count <= 64 << 20 else { throw BSONError("Line \(number + 1) runs past 64 MB: is the file JSON Lines?") }
                let more = try handle.read(upToCount: 1 << 16) ?? Data()
                if more.isEmpty { ended = true } else { buffer.append(contentsOf: more) }
            }
        }

        /// A line without its CR or (on the first) a byte order mark.
        private mutating func line(_ bytes: ArraySlice<UInt8>) -> (Int, ArraySlice<UInt8>) {
            number += 1
            var bytes = bytes
            if number == 1, bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
            if bytes.last == 0x0D { bytes = bytes.dropLast() }
            return (number, bytes)
        }
    }

    static func message(_ error: Error) -> String { (error as? BSONError)?.message ?? error.localizedDescription }

    /// The sheet's look at a file: its first documents, the problems in reading them, and about how many documents it
    /// holds (its size over the first documents' average).
    static func preview(_ url: URL, skipBad: Bool, count: Int = 5) -> (documents: [BSONDocument], problems: [String], estimate: Int) {
        var report = Report()
        var documents: [BSONDocument] = []
        do {
            var source = try Source(url, skipBad: skipBad)
            while documents.count < count, let (document, _) = try source.next(&report) { documents.append(document) }
        } catch {
            report.note(message(error))
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let average = documents.isEmpty ? 0 : documents.map { $0.extendedJSON().utf8.count + 1 }.reduce(0, +) / documents.count
        let estimate = documents.count < count ? documents.count : size / max(1, average)
        return (documents, report.problems, estimate)
    }

    /// Inserts the file's documents into the collection (made by the first insert when it doesn't exist). `skipBad`:
    /// lines that can't be read and documents the server refuses are skipped and counted; else the import stops at the
    /// first of either, the documents before it inserted. `stop` ends it between batches, so the count stays exact.
    /// `progress` gets the documents inserted and how far into the file it is.
    static func run(_ session: MongoSession, database: String, collection: String, file: URL, skipBad: Bool, stop: StopFlag,
                    progress: @escaping @Sendable (Int, Double) -> Void) async -> Report {
        var report = Report()
        let size = Double((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        var batch: [BSONDocument] = [], places: [String] = [], bytes = 0
        do {
            var source = try Source(file, skipBad: skipBad)
            /// Sends the batch; false when the import stops there.
            func send() async throws -> Bool {
                guard !batch.isEmpty else { return true }
                let (inserted, refused) = try await session.insertMany(database: database, collection: collection, batch, ordered: !skipBad)
                report.inserted += Int(inserted)
                for (index, error) in refused {
                    report.refused += 1
                    if error.kind == .duplicate { report.duplicates += 1 }
                    report.note("\(places[index]): \(error.message)")
                }
                (batch, places, bytes) = ([], [], 0)
                progress(report.inserted, size > 0 ? min(1, Double(source.offset) / size) : 1)
                if !skipBad, let first = refused.first { report.stopped = report.problems.last ?? first.error.message }
                return report.stopped == nil
            }
            while true {
                if stop.isSet {
                    report.cancelled = true
                    return report
                }
                let next: (BSONDocument, String)?
                do {
                    next = try source.next(&report)
                } catch {
                    // Only without skipBad: the documents before it go in, as they would have with a smaller file.
                    report.stopped = message(error)
                    report.note(message(error))
                    _ = try await send()
                    return report
                }
                guard let (document, place) = next else { break }
                let length = try document.bytes().count
                if !batch.isEmpty, batch.count == batchCount || bytes + length > batchBytes {
                    guard try await send() else { return report }
                }
                batch.append(document)
                places.append(place)
                bytes += length
            }
            _ = try await send()
        } catch {
            // The connection or the file failed: what went in before stays counted.
            report.stopped = message(error)
            report.note(message(error))
        }
        return report
    }
}
