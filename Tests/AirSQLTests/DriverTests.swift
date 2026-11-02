import AirSQLCore
import Testing

struct DriverTests {
    @Test func clientLibraryIsConnectorC34() {
        #expect(MariaDB.clientVersion.hasPrefix("3.4."), "libmariadb \(MariaDB.clientVersion)")
    }
}
