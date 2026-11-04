import Testing
@testable import AirSQLCore

struct ErrorMappingTests {
    @Test func keepsTheServersNumberAndWords() {
        let error = ErrorMapping.map(code: 1045, sqlState: "28000", message: "Access denied for user 'bob'@'10.0.0.5' (using password: YES)")
        #expect(error.kind == .authFailed)
        #expect(error.message == "The server didn't accept the user name or password.")
        #expect(error.code == 1045 && error.sqlState == "28000")
        #expect(error.details == "Error 1045 (28000): Access denied for user 'bob'@'10.0.0.5' (using password: YES)")
    }

    @Test(arguments: [
        (2003, "Can't connect to server on 'db' (61)", AirSQLError.Kind.refused),
        (2003, "Can't connect to server on 'db' (60)", .timeout),
        (2003, "Can't connect to server on 'db' (65)", .noRoute),
        (2002, "Can't connect to local server through socket '/tmp/x.sock' (2)", .refused),
        (2005, "Unknown server host 'nowhere' (8)", .unknownHost),
        (2013, "Lost connection to server during query", .disconnected),
        (2006, "Server has gone away", .disconnected),
        (1317, "Query execution was interrupted", .cancelled),
        (1064, "You have an error in your SQL syntax; check the manual near 'FORM t' at line 1", .syntax),
        (1062, "Duplicate entry '1' for key 'PRIMARY'", .duplicate),
        (1451, "Cannot delete or update a parent row: a foreign key constraint fails", .foreignKey),
        (1792, "Cannot execute statement in a READ ONLY transaction.", .readOnly),
        (1213, "Deadlock found when trying to get lock; try restarting transaction", .deadlock),
        (1205, "Lock wait timeout exceeded; try restarting transaction", .lockTimeout),
        (1146, "Table 'shop.nope' doesn't exist", .notFound),
        (1142, "SELECT command denied to user 'ro'@'%' for table 'secrets'", .accessDenied),
        (5010, "Authentication plugin 'dialog' couldn't be found in restricted_auth plugin list.", .loginMethodNotAllowed),
        (2026, "TLS/SSL error: SSL is required, but the server does not support it", .tls),
        (3159, "Connections using insecure transport are prohibited while --require_secure_transport=ON.", .tls),
    ])
    func mapsByNumber(code: Int, text: String, kind: AirSQLError.Kind) {
        #expect(ErrorMapping.map(code: code, message: text).kind == kind, "\(code)")
    }

    /// Above 1900 MySQL and MariaDB number errors differently.
    @Test func readsNumbersByFlavor() {
        #expect(ErrorMapping.map(code: 4031, message: "The client was disconnected by the server because of inactivity.").kind
                    == .disconnected)
        #expect(ErrorMapping.map(code: 4031, message: "Referenced trigger 'x' does not exist", mariaDB: true).kind == .other)
        #expect(ErrorMapping.map(code: 4151, message: "Access denied, this account is locked", mariaDB: true).kind == .authFailed)
    }

    @Test func unknownErrorsReadAsTheServerWroteThem() {
        let error = ErrorMapping.map(code: 1356, message: "view 'v' references invalid table(s) or column(s)")
        #expect(error.kind == .other)
        #expect(error.message == "View 'v' references invalid table(s) or column(s).")
    }
}

/// What people read of a server error: plain words, then the server's, once.
struct ErrorWordsTests {
    @Test func theServersWordsFollowThePlainOnes() {
        let typo = ErrorMapping.map(code: 1054, sqlState: "42S22", message: "Unknown column 'nmae' in 'where clause'")
        #expect(typo.localizedDescription == "That column doesn't exist. Error 1054 (42S22): Unknown column 'nmae' in 'where clause'")
        let unmapped = ErrorMapping.map(code: 9999, message: "something odd")
        #expect(unmapped.localizedDescription == "Error 9999: something odd", "said once")
        #expect(ErrorMapping.map(code: 1317, message: "interrupted").localizedDescription == AirSQLError.cancelled.message)
    }

    @Test func everydayErrorsHaveANextStep() {
        for code in [1046, 1048, 1050, 1055, 1067, 1071, 1091, 1175, 1215, 1264, 1292, 1364, 1366, 1406, 1701, 1822, 3819] {
            #expect(ErrorMapping.map(code: code, message: "raw").message != "Raw.", "\(code)")
        }
        #expect(ErrorMapping.map(code: 4025, message: "raw", mariaDB: true).message != "Raw.")
        #expect(ErrorMapping.map(code: 3819, message: "raw", mariaDB: true).message == "Raw.", "MariaDB numbers it otherwise")
    }

    @Test func detailsThatArentTheServersStayOut() {
        let script = AirSQLError(.other, "It failed.", details: "SELECT secret")
        #expect(script.localizedDescription == "It failed.")
    }
}
