import CMongoC
import Foundation

/// Watch Changes (mongo-plan, Phase 4 "watch"): a change stream on a collection or a database, read on a session of its
/// own (a watch tab's slot), as `mongoc_change_stream_next` blocks its thread for up to `maxAwaitTime` while nothing
/// changes. The driver resumes by itself after a resumable error (a step-down, a dropped connection it can make again):
/// it runs the same read-only aggregate again from the resume token, so no event is lost. Anything else ends the stream
/// with an error, which the tab says; it never starts again by itself.
extension MongoSession {
    /// How long one `next` waits on the server for an event.
    static let maxAwaitTime = 1_000

    /// Opens a change stream on `collection` in `database`, or on the whole database (nil). `pipeline` follows
    /// `$changeStream` (a `$match` on the events, `MongoWatch.pipeline`); `lookUp` adds an update's whole document as it is
    /// now (`fullDocument: updateLookup`); `resumeAfter` continues after that resume token.
    public func watch(database: String, collection: String?, pipeline: [BSONDocument], lookUp: Bool,
                      resumeAfter: BSONDocument?) async throws -> MongoChangeStream {
        try await worker.perform { [self] in
            let client = try current()
            let tag = nextTag()
            var stage: [(key: String, value: BSONValue)] = []
            if lookUp { stage.append(("fullDocument", .string("updateLookup"))) }
            if let resumeAfter { stage.append(("resumeAfter", .document(resumeAfter))) }
            // Logged as the aggregate the driver sends.
            log(BSONDocument([("aggregate", collection.map(BSONValue.string) ?? .int32(1)),
                              ("pipeline", .array([.document(BSONDocument([("$changeStream", .document(BSONDocument(stage)))]))]
                                          + pipeline.map { .document($0) })),
                              ("comment", .string(tag))]), database: database)
            let options = try BSONDocument(stage + [("maxAwaitTimeMS", .int64(Int64(Self.maxAwaitTime))),
                                                    ("comment", .string(tag))]).bson()
            let stages = try BSONDocument([("pipeline", .array(pipeline.map { .document($0) }))]).bson()
            defer { [options, stages].forEach { bson_destroy($0) } }
            lock.locked { routeError = nil }
            let made: OpaquePointer?
            if let collection {
                guard let target = mongoc_client_get_collection(client, database, collection) else { throw AirSQLError.disconnected }
                defer { mongoc_collection_destroy(target) }
                made = mongoc_collection_watch(target, stages, options)
            } else {
                guard let target = mongoc_client_get_database(client, database) else { throw AirSQLError.disconnected }
                defer { mongoc_database_destroy(target) }
                made = mongoc_database_watch(target, stages, options)
            }
            guard let made else { throw AirSQLError.disconnected }
            // The aggregate ran as the stream was made: its error (a standalone, history lost) is there now.
            if let failure = streamError(made) {
                mongoc_change_stream_destroy(made)
                throw failure
            }
            streams.insert(made)
            return MongoChangeStream(session: self, stream: made, token: resumeAfter)
        }
    }

    /// The events that came, at most `maxCount`, oldest first (raw BSON); empty after `maxAwaitTime` with none.
    fileprivate func next(_ stream: MongoChangeStream, maxCount: Int) async throws -> [[UInt8]] {
        try await worker.perform { [self] in
            guard let pointer = stream.pointer, streams.contains(pointer) else { throw AirSQLError.disconnected }
            var found: [[UInt8]] = []
            var event: UnsafePointer<bson_t>?
            // A batch the server sent comes at once; the call after it waits for the next (at most maxAwaitTime).
            while found.count < maxCount && mongoc_change_stream_next(pointer, &event) {
                found.append(Array(UnsafeBufferPointer(start: bson_get_data(event!), count: Int(event!.pointee.len))))
            }
            if let token = mongoc_change_stream_get_resume_token(pointer) { stream.token = try? BSONDocument(bson: token) }
            if let failure = streamError(pointer) { throw failure }
            return found
        }
    }

    private func streamError(_ stream: OpaquePointer) -> AirSQLError? {
        var error = bson_error_t()
        var reply: UnsafePointer<bson_t>?
        guard mongoc_change_stream_error_document(stream, &error, &reply) else { return nil }
        return lock.locked { routeError } ?? MongoErrorMapping.map(error, reply: reply)
    }

    fileprivate func close(_ pointer: OpaquePointer) {
        worker.submit { [self] in
            // Gone already when the session closed first.
            if streams.remove(pointer) != nil { mongoc_change_stream_destroy(pointer) }
        }
    }
}

/// An open change stream (`MongoSession.watch`): read it with `next`, then `close` it.
public final class MongoChangeStream: @unchecked Sendable {
    private let session: MongoSession
    private let lock = NSLock()
    private var _pointer: OpaquePointer?
    private var _token: BSONDocument?

    fileprivate init(session: MongoSession, stream: OpaquePointer, token: BSONDocument?) {
        self.session = session
        _pointer = stream
        _token = token
    }

    deinit { if let pointer = _pointer { session.close(pointer) } }

    fileprivate var pointer: OpaquePointer? { lock.locked { _pointer } }

    /// Where the stream has got to: `resumeAfter` it continues from there, without losing an event.
    public fileprivate(set) var token: BSONDocument? {
        get { lock.locked { _token } }
        set { lock.locked { _token = newValue } }
    }

    /// The next events, oldest first; empty when none came within about a second.
    public func next(maxCount: Int = 500) async throws -> [[UInt8]] {
        try await session.next(self, maxCount: max(1, maxCount))
    }

    /// Ends the stream on the server.
    public func close() async {
        if let pointer = lock.locked({ () -> OpaquePointer? in defer { _pointer = nil }; return _pointer }) { session.close(pointer) }
    }
}

/// A watch tab's filter and events (mongo-plan, Phase 4 "watch").
public enum MongoWatch {
    /// The stages after `$changeStream`: the filter typed (shell form, as the query bar's Filter) on the events, as one
    /// `$match`; none when it is empty.
    public static func pipeline(filter: String) throws -> [BSONDocument] {
        let match = try MongoQueryText(filter: filter).find().filter
        return match.fields.isEmpty ? [] : [BSONDocument([("$match", .document(match))])]
    }

    /// The server no longer has the changes after the token (ChangeStreamHistoryLost, or ChangeStreamFatalError before
    /// MongoDB 4.4): the tab then watches from now and says so.
    public static func historyLost(_ error: Error) -> Bool { [286, 280].contains((error as? AirSQLError)?.code) }

    /// Events, newest first, at most `maxCount` and about `maxBytes` (the oldest go first; the newest always stays).
    public struct Events: Sendable {
        public static let maxCount = 10_000
        public static let maxBytes = 32 << 20

        public private(set) var events: [[UInt8]] = []
        public private(set) var bytes = 0
        /// How many old events went to keep within the caps.
        public private(set) var dropped = 0
        let maxCount: Int, maxBytes: Int

        public init(maxCount: Int = Events.maxCount, maxBytes: Int = Events.maxBytes) {
            self.maxCount = maxCount
            self.maxBytes = maxBytes
        }

        /// Adds events as they came (oldest first), dropping the oldest over the caps.
        public mutating func add(_ batch: [[UInt8]]) {
            events = batch.reversed() + events
            bytes += batch.reduce(0) { $0 + $1.count }
            while events.count > 1 && (events.count > maxCount || bytes > maxBytes) {
                bytes -= events.removeLast().count
                dropped += 1
            }
        }
    }
}
