import CMongoC
import Foundation

/// Plain words for MongoDB's errors, as `ErrorMapping` has for MySQL's: the driver's domain and code decide (with error
/// API 2, the server's own codes come in the server domain), the driver's or server's text stays in `details`.
public enum MongoErrorMapping {
    /// `write`: the error ended a write, so a lost connection leaves its outcome unknown. `labels`: the reply's
    /// errorLabels.
    public static func map(domain: UInt32, code: UInt32, message: String, labels: [String] = [], write: Bool = false) -> AirSQLError {
        func error(_ kind: AirSQLError.Kind, _ words: String) -> AirSQLError {
            AirSQLError(kind, words, details: "Error \(code): \(message)", code: Int(code))
        }
        if labels.contains("UnknownTransactionCommitResult") || (write && domain == MONGOC_ERROR_STREAM.rawValue) {
            return error(.outcomeUnknown, "The connection failed before the server answered, so AirSQL can't tell whether "
                + "the change was made. Reload to see.")
        }
        switch (domain, code) {
        case (MONGOC_ERROR_CLIENT.rawValue, MONGOC_ERROR_CLIENT_AUTHENTICATE.rawValue), (MONGOC_ERROR_SERVER.rawValue, 18):
            return error(.authFailed, "The server didn't accept the user name or password.")
        case (MONGOC_ERROR_STREAM.rawValue, MONGOC_ERROR_STREAM_NAME_RESOLUTION.rawValue):
            return error(.unknownHost, "Can't find the server. Check the host name and your network connection.")
        case (MONGOC_ERROR_STREAM.rawValue, MONGOC_ERROR_STREAM_CONNECT.rawValue):
            return error(.refused, "Can't connect to the server. Check the host name, the port and that the database "
                + "server is running.")
        case (MONGOC_ERROR_STREAM.rawValue, _):
            if message.localizedCaseInsensitiveContains("timeout") || message.localizedCaseInsensitiveContains("timed out") {
                return error(.timeout, "The server didn't answer in time. Check the host name, the port and your network.")
            }
            return error(.disconnected, AirSQLError.disconnected.message)
        case (MONGOC_ERROR_SERVER_SELECTION.rawValue, _):
            if message.localizedCaseInsensitiveContains("authenticat") {
                return error(.authFailed, "The server didn't accept the user name or password.")
            }
            if message.localizedCaseInsensitiveContains("TLS") || message.localizedCaseInsensitiveContains("handshake") {
                return error(.tls, "TLS couldn't be set up with the server. Check the connection's TLS tab.")
            }
            if message.localizedCaseInsensitiveContains("timed out") {
                return error(.timeout, "The server didn't answer in time. Check the host name, the port and your network.")
            }
            return error(.refused, "No server of this connection answered. Check the host names, the ports and that "
                + "the servers are running.")
        case (MONGOC_ERROR_WRITE_CONCERN.rawValue, _):
            return error(.other, "The change was made, but not confirmed by as many servers as asked (its write concern).")
        case (MONGOC_ERROR_SERVER.rawValue, _):
            break
        default:
            return AirSQLError(.other, message, code: Int(code))
        }
        switch code {
        case 13:
            return error(.accessDenied, "This user lacks the privilege for that.")
        case 50:
            return error(.timeout, "The command ran longer than its time limit, so the server stopped it.")
        case 11601:
            return error(.cancelled, "The command was cancelled.")
        case 10107, 13435, 13436, 189, 11602:
            return error(.readOnly, "This server isn't the replica set's primary now (it may be changing). Try again in a "
                + "moment.")
        case 20 where message.contains("Transaction numbers"):
            return error(.other, "Transactions need a replica set; this server runs on its own.")
        case 20, 59, 115, 263:
            return error(.other, "The server doesn't allow that command here.")
        case 11000:
            return error(.duplicate, "A document with the same key already exists.")
        case 26:
            return error(.notFound, "That database or collection doesn't exist.")
        case 2, 9:
            return error(.syntax, "The server didn't accept the command as written.")
        case 112:
            return error(.deadlock, "Another change touched the same documents at the same time. Try again.")
        case 121:
            return error(.other, "The document breaks the collection's validation rules.")
        default:
            return AirSQLError(.other, message, details: "Error \(code)", code: Int(code))
        }
    }

    /// A driver's error, with the reply (or the cursor's error document) that came with it.
    static func map(_ error: bson_error_t, reply: UnsafePointer<bson_t>? = nil, write: Bool = false) -> AirSQLError {
        let labels = reply.map { reply in
            ["UnknownTransactionCommitResult", "TransientTransactionError"].filter { (label: String) in
                mongoc_error_has_label(reply, label)
            }
        } ?? []
        return map(domain: error.domain, code: error.code, message: MongoSession.text(error.message), labels: labels, write: write)
    }
}

/// The command log: every command AirSQL sends to MongoDB, in the SQL log's file (`SQLLog`), in shell form. Not SQL,
/// so not masked as SQL: the values of fields named as secrets are replaced instead, at any depth.
enum MongoLog {
    /// Lower case. Not "key": an index's keys and distinct's field are no secrets, and naming them helps.
    static let secretFields: Set = ["pwd", "password", "newpassword", "secret", "keymaterial", "payload", "saslpayload"]

    static func redacted(_ document: BSONDocument) -> BSONDocument {
        BSONDocument(document.fields.map { field in
            if secretFields.contains(field.key.lowercased()) { return (field.key, .string("<secret>")) }
            return (field.key, redacted(field.value))
        })
    }

    private static func redacted(_ value: BSONValue) -> BSONValue {
        switch value {
        case .document(let document): return .document(redacted(document))
        case .array(let values): return .array(values.map(redacted))
        default: return value
        }
    }

    /// The line the log gets for `command`: redacted, and only its start when it is long (an import's 1,000 documents).
    static func line(_ command: BSONDocument) -> String {
        let text = redacted(command).shellForm()
        guard text.utf8.count > 65_536 else { return text }
        return String(decoding: text.utf8.prefix(60_000), as: UTF8.self) + " … (\(text.utf8.count - 60_000) more bytes)"
    }
}
