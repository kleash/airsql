import CMariaDB

/// The client library AirSQL ships: MariaDB Connector/C (scripts/build-mariadb.sh).
public enum MariaDB {
    /// Its version, such as "3.4.11".
    public static var clientVersion: String { String(cString: mysql_get_client_info()) }
}
