import Foundation
import Testing
@testable import AirSQLCore

/// Connections from elsewhere, from fixtures written here: no real app's file is read.
@Suite struct ConnectionImportTests {
    static let secret = "must-not-appear"

    private func plist(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }

    private func expectNoSecret(_ found: [SavedConnection]) throws {
        let text = String(decoding: try ConnectionImport.export(found), as: UTF8.self)
        #expect(!text.contains(Self.secret))
    }

    @Test func aURLGivesItsPartsAndNeverItsPassword() throws {
        let saved = try #require(ConnectionImport.connection(fromURL: " mysql://app:\(Self.secret)@db.example.com:3307/shop?ssl=true\n"))
        #expect(saved.host == "db.example.com" && saved.port == 3307 && saved.user == "app" && saved.database == "shop")
        #expect(saved.tls.mode == .verifyIdentity)
        try expectNoSecret([saved])
        let local = try #require(ConnectionImport.connection(fromURL: "mariadb://root@[::1]:3306"))
        #expect(local.host == "::1" && local.port == nil && local.tls.mode == .off)
        for wrong in ["postgres://a@b/c", "mysql://", "db.example.com", ""] { #expect(ConnectionImport.connection(fromURL: wrong) == nil) }
    }

    @Test func anExportComesBackAsNewConnectionsWithoutWhatWouldRunByItself() throws {
        var saved = SavedConnection(name: "Shop", host: "db.example.com", port: 3307, user: "app", colour: .production, route: .ssh)
        saved.sshHost = SSHHop(host: "bastion.example.com", user: "deploy")
        saved.folderID = UUID()
        saved.readOnly = true
        saved.tls.pinnedFingerprint = "AB:CD"
        saved.dumpPath = "/tmp/evil"
        saved.clientPath = "/tmp/evil"
        saved.startupSQL = "DROP TABLE orders"
        saved.agentAccess = .schemaReadAnalytics
        saved.agentSampleRows = true
        let back = try #require(ConnectionImport.connections(in: try ConnectionImport.export([saved])).first)
        #expect(back.id != saved.id && back.folderID == nil)
        #expect(back.name == "Shop" && back.host == saved.host && back.port == 3307 && back.user == "app" && back.colour == .production)
        #expect(back.route == .ssh && back.sshHost.host == "bastion.example.com" && back.readOnly && back.tls.pinnedFingerprint == "AB:CD")
        #expect(back.dumpPath.isEmpty && back.clientPath.isEmpty && back.startupSQL.isEmpty)
        #expect(back.agentAccess == .off && !back.agentSampleRows)
    }

    @Test func sequelAceFavoritesInGroupsWithTheirRoutes() throws {
        let tcp: [String: Any] = ["name": "Local", "host": "127.0.0.1", "port": "3306", "user": "root", "database": "shop", "type": 0,
                                  "password": Self.secret]
        let socket: [String: Any] = ["name": "Socket", "socket": "/tmp/mysql.sock", "user": "root", "type": 1]
        let ssh: [String: Any] = ["name": "Remote", "host": "10.0.0.5", "port": 3307, "user": "app", "type": 2, "sshHost": "bastion.example.com",
                                  "sshPort": "2222", "sshUser": "deploy", "sshPassword": Self.secret]
        let tree: [String: Any] = ["Favorites Root": ["Name": "FAVORITES", "Children": [tcp, ["Name": "Group", "Children": [socket, ssh]]]]]
        let found = ConnectionImport.connections(in: try plist(tree))
        #expect(found.map(\.displayName) == ["Local", "Socket", "Remote"])
        #expect(found[0].database == "shop" && found[0].port == nil && found[0].tls.mode == .off)
        #expect(found[1].socket == "/tmp/mysql.sock")
        #expect(found[2].route == .ssh && found[2].host == "10.0.0.5" && found[2].port == 3307 && found[2].tls.mode == .verifyIdentity)
        #expect(found[2].sshHost.host == "bastion.example.com" && found[2].sshHost.port == 2222 && found[2].sshHost.user == "deploy")
        try expectNoSecret(found)
    }

    @Test func tablePlusKeepsOnlyMySQLAndMariaDB() throws {
        let list: [[String: Any]] = [
            ["ConnectionName": "Shop", "Driver": "MySQL", "DatabaseHost": "db.example.com", "DatabasePort": "3307", "DatabaseUser": "app",
             "DatabaseName": "shop", "DatabasePassword": Self.secret],
            ["ConnectionName": "Maria", "Driver": "MariaDB", "DatabaseHost": "10.0.0.5", "DatabaseUser": "app", "isOverSSH": true,
             "ServerAddress": "bastion.example.com", "ServerPort": "22", "ServerUser": "deploy"],
            ["ConnectionName": "Elephant", "Driver": "PostgreSQL", "DatabaseHost": "pg.example.com"],
        ]
        let found = ConnectionImport.connections(in: try plist(list))
        #expect(found.map(\.displayName) == ["Shop", "Maria"])
        #expect(found[0].port == 3307 && found[0].database == "shop" && found[1].route == .ssh && found[1].sshHost.user == "deploy")
        try expectNoSecret(found)
    }

    @Test func dbeaverReadsItsFieldsOrItsURL() throws {
        let json: [String: Any] = ["connections": [
            "mysql8-1": ["provider": "mysql", "driver": "mysql8", "name": "Shop",
                         "configuration": ["host": "db.example.com", "port": "3307", "database": "shop", "user": "app"]],
            "mysql8-2": ["provider": "mysql", "name": "ByURL", "configuration": ["url": "jdbc:mysql://h.example.com:3310/orders"]],
            "postgres-1": ["provider": "postgresql", "name": "Elephant", "configuration": ["host": "pg.example.com"]],
        ]]
        let found = ConnectionImport.connections(in: try JSONSerialization.data(withJSONObject: json))
        #expect(found.map(\.displayName) == ["Shop", "ByURL"])
        #expect(found[0].user == "app" && found[1].host == "h.example.com" && found[1].port == 3310 && found[1].database == "orders")
    }

    @Test func workbenchConnectionsWithAndWithoutSSH() throws {
        let xml = """
        <?xml version="1.0"?>
        <data grt_format="2.0">
          <value type="list" content-type="object" content-struct-name="db.mgmt.Connection">
            <value type="object" struct-name="db.mgmt.Connection" id="a">
              <value type="string" key="name">Shop</value>
              <value type="dict" key="parameterValues">
                <value type="string" key="hostName">db.example.com</value>
                <value type="int" key="port">3307</value>
                <value type="string" key="userName">app</value>
                <value type="string" key="schema">shop</value>
              </value>
            </value>
            <value type="object" struct-name="db.mgmt.Connection" id="b">
              <value type="string" key="name">Tunnel</value>
              <value type="dict" key="parameterValues">
                <value type="string" key="hostName">10.0.0.5</value>
                <value type="int" key="port">3306</value>
                <value type="string" key="userName">app</value>
                <value type="string" key="sshHost">bastion.example.com:2222</value>
                <value type="string" key="sshUserName">deploy</value>
              </value>
            </value>
          </value>
        </data>
        """
        let found = ConnectionImport.connections(in: Data(xml.utf8))
        #expect(found.map(\.displayName) == ["Shop", "Tunnel"])
        #expect(found[0].host == "db.example.com" && found[0].port == 3307 && found[0].user == "app" && found[0].database == "shop")
        #expect(found[1].route == .ssh && found[1].sshHost.host == "bastion.example.com" && found[1].sshHost.port == 2222)
    }

    @Test func heidiSQLSettingsSkipOtherServersAndPasswords() throws {
        let text = #"""
        Servers\Shop\Host<|||>1<|||>db.example.com
        Servers\Shop\User<|||>1<|||>app
        Servers\Shop\Password<|||>1<|||>must-not-appear
        Servers\Shop\Port<|||>1<|||>3307
        Servers\Shop\NetType<|||>3<|||>0
        Servers\Shop\Databases<|||>1<|||>shop;orders
        Servers\Folder\Tunnel\Host<|||>1<|||>10.0.0.5
        Servers\Folder\Tunnel\NetType<|||>3<|||>2
        Servers\Folder\Tunnel\SSHtunnelHost<|||>1<|||>bastion.example.com
        Servers\Elephant\Host<|||>1<|||>pg.example.com
        Servers\Elephant\NetType<|||>3<|||>7
        """#
        let found = ConnectionImport.connections(in: Data(text.utf8))
        #expect(found.map(\.displayName) == ["Shop", "Tunnel"])
        #expect(found[0].port == 3307 && found[0].user == "app" && found[0].database == "shop")
        #expect(found[1].route == .ssh && found[1].sshHost.host == "bastion.example.com")
        try expectNoSecret(found)
    }

    @Test func aFileOfNoKnownFormatGivesNothing() {
        for text in ["", "hello", "{}", "[]", "<html></html>", "{\"a\": 1}"] { #expect(ConnectionImport.connections(in: Data(text.utf8)).isEmpty) }
    }
}
