import Foundation

/// Open mongosh in Terminal (mongo-plan, Phase 2 aggregate): the person's own mongosh, found where the client tools are
/// looked for, on the connection's route socket with `directConnection` (or the server itself for Direct). Only the user
/// goes on the command line, so mongosh asks for the password in Terminal: no password on argv, in a file or in the
/// environment.
public enum MongoShell {
    /// mongosh in the client tools' folders (Homebrew's, /usr/local/bin, PATH…); nil when it isn't installed. File work.
    public static func find(folders: [String] = ClientTools.searchFolders()) -> String? {
        folders.map { $0 + "/mongosh" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The socket of the server mongosh should talk to over `route`: the primary's, else the first server's; nil for
    /// Direct. It may open the server's forward first: off the main thread.
    public static func socket(_ route: MongoRoute, saved: SavedConnection, primary: String?) throws -> String? {
        guard saved.route != .direct else { return nil }
        let server = primary.flatMap(MongoURI.split) ?? MongoURI.split(MongoURI.join(saved.host, saved.port))
        return try route.socket(host: server?.host ?? saved.host, port: server?.port ?? 27017)
    }

    /// mongosh's arguments: the connection string (the route's socket, or the saved servers for Direct) with TLS's
    /// options (and the client certificate's file), then `--username` alone; for X.509 no user, as the certificate logs
    /// in and nothing is asked. `nameUnchecked`: over a route, TLS can't check the server's name, as mongosh only sees
    /// the socket.
    public static func arguments(_ saved: SavedConnection, mongosh: String, socket: String?) -> (argv: [String], nameUnchecked: Bool) {
        var uri = saved.mongoURI
        uri.setOption("connectTimeoutMS", nil)
        let tls = saved.tls.mode != .off
        if let socket {
            // One server through its socket: the driver can't reach the others by their names.
            uri.srv = false
            uri.hosts = [MongoURI.encode(socket)]
            uri.setOption("replicaSet", nil)
            uri.setOption("directConnection", "true")
        }
        if tls {
            if let ca = saved.tls.caFile, !ca.isEmpty { uri.setOption("tlsCAFile", ca) }
            if let pem = saved.tls.certFile, !pem.isEmpty { uri.setOption("tlsCertificateKeyFile", pem) }
            if saved.tls.mode == .required { uri.setOption("tlsAllowInvalidCertificates", "true") }
            if saved.tls.mode == .verifyCA || socket != nil { uri.setOption("tlsAllowInvalidHostnames", "true") }
        }
        var argv = [mongosh, uri.string]
        if !saved.user.isEmpty, !saved.mongoX509 { argv += ["--username", saved.user] }
        return (argv, tls && socket != nil)
    }

    /// Terminal's script: it removes itself, prints `notes`, and becomes mongosh.
    static func script(_ argv: [String], notes: [String]) -> String {
        "#!/bin/sh\nrm -f -- \"$0\"\n" + notes.map { "echo " + ToolCommand.shellWord("AirSQL: " + $0) + "\n" }.joined()
            + "exec " + argv.map(ToolCommand.shellWord).joined(separator: " ") + "\n"
    }

    /// Opens Terminal running `argv` after `notes`, through a script in the client tools' private folder that removes
    /// itself as it starts (the app removes it after two minutes when Terminal never ran it).
    public static func openInTerminal(_ argv: [String], notes: [String], name: String) async throws {
        let safe = String(name.map { "/:\n".contains($0) ? "-" : $0 }.prefix(60))
        let url = try OptionFile.create(Data(script(argv, notes: notes).utf8),
                                        named: "\(safe) mongosh \(UUID().uuidString.prefix(6).lowercased()).command", mode: 0o700)
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) { unlink(url.path) }
        let result = await Runner.run(["/usr/bin/open", "-a", "Terminal", url.path])
        guard result.status == 0 else {
            unlink(url.path)
            throw AirSQLError(.other, "Terminal couldn't open mongosh.", details: result.stderr)
        }
    }
}
