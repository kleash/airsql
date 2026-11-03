// What the route tests share: ssh kept away from ~/.ssh, the askpass helper, and an askpass server that answers.
import Foundation
@testable import AirSQLCore

/// The tunnels' ssh in tests: AirSQL's ssh_config includes the tests' own config (a known_hosts of the tests', no agent,
/// no default keys) instead of ~/.ssh/config, and runs with the tests' environment. The askpass program is the debug
/// AirSQL (next to the test bundle), through a script that tells it where libmariadb is: ssh, a system program, drops
/// DYLD_ variables from its own environment.
enum RouteTesting {
    static let prepared: Void = {
        _ = TestEnvironment.isolated
        let config = TestEnvironment.root + "/airsql_include_config"
        try? """
            Host *
              UserKnownHostsFile "\(TestEnvironment.root)/routes_known_hosts"
              GlobalKnownHostsFile /dev/null
              IdentityAgent none
              IdentitiesOnly yes

            """.write(toFile: config, atomically: true, encoding: .utf8)
        SSHConfig.include = config
        Tunnel.environmentOverrides = ["HOME": TestEnvironment.root + "/local-home", "SSH_AUTH_SOCK": ""]
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let binary = Bundle(for: RoutesMarker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("AirSQL").path
        let library = repository.appendingPathComponent("vendor/out/universal/lib").path
        try? "#!/bin/sh\nDYLD_LIBRARY_PATH='\(library)' exec '\(binary)' \"$@\"\n"
            .write(toFile: askpassHelper, atomically: true, encoding: .utf8)
        chmod(askpassHelper, 0o755)
    }()

    static var askpassHelper: String { TestEnvironment.root + "/askpass.sh" }

    /// An askpass server for connection `id` that trusts host keys and answers passwords and passphrases from
    /// `secrets` (by the prompt's host, or "passphrase"), recording every prompt; anything else is cancelled.
    static func askpass(for id: UUID, secrets: [String: String] = [:], prompts: Recorder<String>? = nil) throws -> AskpassServer {
        _ = prepared
        let server = try AskpassServer(helperPath: askpassHelper)
        server.setHandler({ request, reply in
            prompts?.append(request.prompt)
            switch request.kind {
            case .hostKey: reply("yes")
            case .password(_, let host): reply(host.flatMap { secrets[$0] })
            case .passphrase: reply(secrets["passphrase"])
            case .other: reply(nil)
            }
        }, for: id.uuidString)
        return server
    }
}

private final class RoutesMarker {}
