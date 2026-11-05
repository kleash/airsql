import CMariaDB
import Foundation

/// An error with a message for people and, under "Details", the server's (or the client library's) own number and
/// words, kept as they were.
public struct AirSQLError: Error, LocalizedError, Equatable {
    public enum Kind: Equatable {
        /// The server refused the login: user name, password, the computer's address or the login method.
        case authFailed
        /// The login method the server asked for isn't allowed on this connection (or isn't built into AirSQL).
        case loginMethodNotAllowed
        /// The user lacks a privilege for what was asked.
        case accessDenied
        case unknownHost, refused, timeout, noRoute
        /// The connection is gone. It is reported, never re-made behind the user's back: Reconnect is explicit.
        case disconnected
        case cancelled
        /// TLS couldn't be set up, or the server doesn't offer it.
        case tls
        /// The server's certificate failed the check: the Trust sheet can show it and pin its fingerprint.
        case untrustedCertificate(TLSCertificate)
        /// The server showed another certificate than the one pinned for this connection.
        case certificateChanged(TLSCertificate)
        case syntax, notFound, duplicate, foreignKey, readOnly, deadlock, lockTimeout
        /// An SSH host showed another host key than the one known for it (`ErrorMapping.ssh`).
        case hostKeyChanged
        case other
    }

    public var kind: Kind
    public var message: String
    public var details: String
    /// The server's or Connector/C's error number (1045, 2013, …); 0 for AirSQL's own errors.
    public var code: Int
    public var sqlState: String

    public init(_ kind: Kind, _ message: String, details: String = "", code: Int = 0, sqlState: String = "") {
        self.kind = kind
        self.message = message
        self.details = details
        self.code = code
        self.sqlState = sqlState
    }

    /// What people read: the plain words, then the server's own, which name the column or the place in the SQL. Only
    /// the server's: other `details` hold a tool's output or the SQL itself. An unmapped message already is the server's.
    public var errorDescription: String? {
        guard code != 0, !details.isEmpty, kind != .cancelled else { return message }
        return details.localizedCaseInsensitiveContains(message.dropLast()) ? details : message + " " + details
    }

    public static let cancelled = AirSQLError(.cancelled, "The statement was cancelled.")
    public static let disconnected = AirSQLError(.disconnected, "The connection to the server was lost. Connect again to go on.")
}

/// Plain words for MySQL's and MariaDB's errors. The number decides (MySQL and MariaDB number some errors above 1900
/// differently, hence `mariaDB`); the server's text stays in `details`.
public enum ErrorMapping {
    public static func map(code: Int, sqlState: String = "", message serverText: String, mariaDB: Bool = false) -> AirSQLError {
        let text = serverText.trimmingCharacters(in: .whitespacesAndNewlines)
        func error(_ kind: AirSQLError.Kind, _ message: String) -> AirSQLError {
            let state = sqlState.isEmpty || sqlState == "HY000" ? "" : " (\(sqlState))"
            return AirSQLError(kind, message, details: "Error \(code)\(state): \(text)", code: code, sqlState: sqlState)
        }
        // The system error Connector/C puts last in a failed connect: "Can't connect to server on 'db' (61)".
        let systemError = text.range(of: #"\((\d+)\)$"#, options: .regularExpression)
            .flatMap { Int32(text[$0].dropFirst().dropLast()) }

        switch code {
        // Logins and privileges
        case 1045:
            return error(.authFailed, "The server didn't accept the user name or password.")
        case 1698:
            return error(.authFailed, "The server didn't accept this login: the account may only log in another way, for "
                + "example from the server itself.")
        case 1130:
            return error(.authFailed, "This user may not log in from this computer's address. An administrator can allow "
                + "it (the user's host part).")
        case 1820, 1862:
            return error(.authFailed, "The password has expired. Connect from AirSQL to set a new one, or change it with the server's own tools.")
        case 1251, 2059:
            return error(.loginMethodNotAllowed, "The server asked for a login method AirSQL doesn't have.")
        case Int(CR_PLUGIN_NOT_ALLOWED):
            return error(.loginMethodNotAllowed, "The server asked for a login method AirSQL doesn't allow on this "
                + "connection.")
        case 2061:
            return error(.authFailed, "The login failed: \(text)")
        case 1044:
            return error(.accessDenied, "This user may not use that database.")
        case 1142, 1143, 1227, 1370, 1095:
            return error(.accessDenied, "This user lacks the privilege for that.")
        case 3118 where !mariaDB, 4151 where mariaDB:
            return error(.authFailed, "This account is locked. An administrator can unlock it.")
        case 1129:
            return error(.refused, "The server blocked this computer after too many failed connections. An administrator "
                + "can unblock it (FLUSH HOSTS).")
        case 1040:
            return error(.refused, "The server has too many connections open. Try again in a moment.")
        case 1203, 1226:
            return error(.refused, "This user has reached a limit the server sets (connections or queries). Try again "
                + "later or close other connections.")
        case 3159 where !mariaDB:
            return error(.tls, "The server only accepts encrypted connections: turn on TLS for this connection.")

        // Reaching the server
        case 2005:
            return error(.unknownHost, "Can't find the server. Check the host name and your network connection.")
        case 2002, 2003:
            switch systemError {
            case ENOENT:
                return error(.refused, "The server's socket isn't there. Check that the server (or the tunnel) is running.")
            case ECONNREFUSED:
                return error(.refused, "The server refused the connection. Check the port and that the database server is "
                    + "running.")
            case ETIMEDOUT:
                return error(.timeout, "The server didn't answer in time. Check the host name, the port and your network.")
            case EHOSTUNREACH, ENETUNREACH, ENETDOWN, EHOSTDOWN:
                return error(.noRoute, "The server can't be reached from this network. Check Wi-Fi or VPN, or connect "
                    + "through an SSH host.")
            default:
                return error(.refused, "Can't connect to the server. Check the host name, the port and that the database "
                    + "server is running.")
            }
        case 2006, 2013, 2055, 1053, 1927, Int(CR_ERR_NET_READ), Int(CR_ERR_NET_WRITE), 1159, 1161:
            return error(.disconnected, AirSQLError.disconnected.message)
        case 4031 where !mariaDB:
            return error(.disconnected, "The server closed the connection because it was idle too long. Connect again to go on.")
        case 2026:
            if text.contains("does not support it") {
                return error(.tls, "The server doesn't offer TLS. Turn TLS off for this connection only if you trust every "
                    + "network between this Mac and the server.")
            }
            return error(.tls, "TLS couldn't be set up with the server. Check the files in this connection's TLS tab, or "
                + "ask the server's administrator.")

        // Statements
        case 1317:
            return error(.cancelled, AirSQLError.cancelled.message)
        case 3024, 1969:
            return error(.timeout, "The statement ran longer than its time limit, so the server stopped it.")
        case 1064, 1149:
            return error(.syntax, "The SQL has a syntax error.")
        case 1049:
            return error(.notFound, "That database doesn't exist.")
        case 1146:
            return error(.notFound, "That table doesn't exist.")
        case 1054:
            return error(.notFound, "That column doesn't exist.")
        case 1062, 1586:
            return error(.duplicate, "A row with the same key already exists.")
        case 1451, 1217:
            return error(.foreignKey, "Other rows refer to this row (a foreign key), so it can't be deleted or changed.")
        case 1452, 1216:
            return error(.foreignKey, "The value refers to a row that doesn't exist (a foreign key).")
        case 1792:
            return error(.readOnly, "This session is read-only, so it can't change data.")
        case 1290, 1836:
            return error(.readOnly, "The server doesn't allow this now (it may be read-only).")
        case 1046:
            return error(.other, "No database is chosen. Pick one in the toolbar, or write it in the SQL (database.table).")
        case 1048:
            return error(.other, "This column can't be NULL: give it a value.")
        case 1050:
            return error(.other, "A table with that name already exists. Choose another name.")
        case 1055:
            return error(.other, "A selected column isn't in GROUP BY. Add it there, or wrap it in a function such as MAX().")
        case 1067:
            return error(.other, "The default value doesn't suit the column's type. Change it or remove it.")
        case 1071:
            return error(.other, "The key is too long for this server. Index fewer columns, or only the start of a long text "
                + "column.")
        case 1091:
            return error(.notFound, "That column or key doesn't exist, so it can't be dropped. Check the name.")
        case 1175:
            return error(.other, "Safe updates are on, and this statement has no WHERE that uses a key. Add one, or run "
                + "SET sql_safe_updates = 0 first.")
        case 1215, 1822:
            return error(.foreignKey, "The foreign key can't be added. Both columns need the same type, and the column it "
                + "refers to needs an index.")
        case 1264:
            return error(.other, "The value is out of range for this column. Use a smaller one, or a wider column type.")
        case 1292, 1366:
            return error(.other, "A value doesn't suit its column's type. Check how it is written, for example a date.")
        case 1364:
            return error(.other, "A column with no default needs a value. Give it one, or add a default to the column.")
        case 1406:
            return error(.other, "The value is too long for this column. Shorten it, or make the column wider.")
        case 1701:
            return error(.foreignKey, "A foreign key refers to this table, so it can't be emptied. Delete the rows instead.")
        case 3819 where !mariaDB, 4025 where mariaDB:
            return error(.other, "A value breaks one of the table's CHECK rules. Change it to suit the rule.")
        case 1205:
            return error(.lockTimeout, "Another session holds a lock on these rows, and waiting for it timed out. Try again.")
        case 1213:
            return error(.deadlock, "The statement ran into a deadlock with another session, and the server rolled back "
                + "the transaction. Try again.")
        default:
            if text.localizedCaseInsensitiveContains("insecure transport") {
                return error(.tls, "The server only accepts encrypted connections: turn on TLS for this connection.")
            }
            let sentence = text.isEmpty ? "The server reported error \(code)." : text.prefix(1).uppercased() + text.dropFirst()
            return error(.other, sentence.hasSuffix(".") ? sentence : sentence + ".")
        }
    }

    /// The error a call on `mysql` left behind.
    static func map(_ mysql: UnsafeMutablePointer<MYSQL>, mariaDB: Bool) -> AirSQLError {
        map(code: Int(mysql_errno(mysql)), sqlState: String(cString: mysql_sqlstate(mysql)),
            message: String(cString: mysql_error(mysql)), mariaDB: mariaDB)
    }
}
