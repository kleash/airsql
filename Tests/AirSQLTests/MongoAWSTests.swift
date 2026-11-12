@testable import AirSQLCore
import Foundation
import Testing

/// AWS IAM logins (MONGODB-AWS): the access key ID is the user, its secret the password, the session token only in
/// memory; the address keeps no secret.
struct MongoAWSTests {
    private static func saved(_ address: String) throws -> (SavedConnection, String?) {
        var saved = SavedConnection(name: "IAM")
        saved.engine = .mongodb
        let password = saved.apply(try MongoURI(address))
        return (saved, password)
    }

    @Test func anAWSLoginIsInTheAddressBothWays() throws {
        let (saved, secret) = try Self.saved("mongodb+srv://AKIAEXAMPLE:s%2Fecret@cluster0.example.net/app?authMechanism=MONGODB-AWS"
                                             + "&authMechanismProperties=AWS_SESSION_TOKEN%3Atok%2Fen%3D&authSource=%24external")
        #expect(saved.mongoAWS && !saved.mongoX509 && saved.user == "AKIAEXAMPLE" && secret == "s/ecret")
        // The token never lands in the saved options, and the database isn't taken as where the login lives.
        #expect(saved.mongoOptions.isEmpty && saved.authSource == "$external")
        var uri = saved.mongoURI
        #expect(uri.option("authMechanism") == "MONGODB-AWS" && uri.option("authSource") == nil)
        #expect(uri.option("authMechanismProperties") == nil && uri.user == nil && uri.password == nil)
        uri.user = saved.user  // Copy Address: the access key ID, which isn't a secret, but never the secret or token
        #expect(!uri.string.contains("ecret") && !uri.string.contains("tok"))
        var scram = saved
        scram.mongoAWS = false
        #expect(scram.mongoURI.option("authMechanism") == nil)
        // A token for another mechanism is that address's own option, kept as written.
        let (other, _) = try Self.saved("mongodb://db1/?authMechanismProperties=SERVICE_NAME%3Amongo")
        #expect(!other.mongoAWS && other.mongoOptions == "authMechanismProperties=SERVICE_NAME%3Amongo")
    }

    /// The driver's own search for keys (environment, ECS, EC2) is never used: no key, no attempt.
    @Test func anEmptyAccessKeyIsRefusedBeforeAnythingIsSent() async throws {
        var saved = SavedConnection(name: "IAM", host: "127.0.0.1", port: 9)
        saved.engine = .mongodb
        saved.mongoAWS = true
        for (user, password, words, kind) in [(nil, "secret", "access key ID", AirSQLError.Kind.other),
                                              ("AKIAEXAMPLE", nil, "secret access key", .authFailed)] {
            let connection = MongoConnection(uri: saved.mongoURI.string, user: user, password: password,
                                             route: MongoRoute(saved))
            await #expect { try await connection.connect() } throws: {
                let error = $0 as? AirSQLError
                return error?.kind == kind && error?.message.contains(words) == true
            }
            await connection.close()
        }
    }

    /// Community servers have no MONGODB-AWS: AirSQL's attempt reaches the server, which refuses the mechanism, and the
    /// person reads that in plain words (untested against Atlas, which has it).
    @Test(.enabled(if: MongoLab.enabled), arguments: [false, true])
    func theLoginIsAttemptedAndTheServerSaysItHasNoAWS(_ replicaSet: Bool) async throws {
        var saved = SavedConnection(name: "IAM", host: replicaSet ? MongoLab.members[0] : "127.0.0.1",
                                    port: replicaSet ? 27017 : MongoLab.soloPort, route: replicaSet ? .proxy : .direct)
        saved.engine = .mongodb
        saved.mongoAWS = true
        if replicaSet {
            saved.mongoHosts = MongoLab.members.dropFirst().map { $0 + ":27017" }
            saved.replicaSet = "rs0"
            saved.tls = TLSOptions(mode: .verifyIdentity, caFile: Lab.caFile)
            saved.proxy = ProxySettings(kind: .socks5, host: "127.0.0.1", port: Lab.socksProxy.port, user: Lab.socksProxy.user)
        } else {
            saved.tls.mode = .off
        }
        let connection = MongoConnection(uri: saved.mongoURI.string, user: "AKIAEXAMPLE", password: "secret", tls: saved.tls,
                                         route: MongoRoute(saved, proxyPassword: Lab.socksProxy.password), name: saved.name)
        connection.awsSessionToken = "token"
        // The server's own refusal of the mechanism: the attempt was made with the key, over the route.
        await #expect { try await connection.connect() } throws: {
            let error = $0 as? AirSQLError
            return error?.kind == .loginMethodNotAllowed && error?.code == 334 && error?.message.contains("AWS IAM") == true
        }
        await connection.close()
    }
}
